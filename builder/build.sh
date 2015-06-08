#!/bin/bash

readonly API_BASE_URL=https://rebuilds.foutrelis.com
readonly AUTH_TOKEN=$(< $HOME/.arch-rebuilds-token)
readonly VERSION=$(< $(dirname $0)/version)
readonly BASE_DIR=$(dirname $(readlink -f -- "$0"))

api_call() {
	local action=$1; shift
	local params=(--data-urlencode "version=$VERSION" --data-urlencode "token=$AUTH_TOKEN")

	while [[ -n $1 ]]; do
		params+=(--data-urlencode "$1")
		shift
	done

	local url="$API_BASE_URL/$action"
	local result=($(curl -s -w ' %{http_code}' "$url" "${params[@]}"))

	if [[ ${#result[@]} -lt 2 ]]; then
		echo "Got empty response for API call: $action" >&2
		return 1
	fi

	local ret=${result[-1]}
	unset result[-1]

	if [[ $ret != 200 ]]; then
		echo "Got HTTP error $ret for API call: $action" >&2
		return 1
	fi

	echo "${result[@]}"
}

build_i686() {
	local base=$1
	cxx11abi-celestia-build $base cxx11abi i686 cxx11abi-i686-build
}

build_x86_64() {
	local base=$1
	cxx11abi-celestia-build $base cxx11abi x86_64 cxx11abi-x86_64-build
}

build_multilib() {
	local base=$1 repo=${2:-cxx11abi-multilib}
	cxx11abi-celestia-build $base $repo x86_64 multilib-cxx11abi-build
}

abort_build() {
	local base=$1
	api_call update base=$base status=pending
}

try_build() {
	local result=($(api_call fetch))

	if [[ -z $result ]]; then
		return
	elif [[ $result == NOPKG ]]; then
		return
	elif [[ $result != OK ]]; then
		echo "Got $result response for API call: fetch" >&2
		return
	fi

	local base=${result[1]}
	local repos=(${result[@]:2})
	local buildcmd arches arch
	local builddir=$(mktemp -d -p "$BASE_DIR")

	trap "rm -rf \"$builddir\"" EXIT
	trap "abort_build $base; trap - INT; kill -INT $$" INT

	pushd "$builddir" > /dev/null

	{ archco $base || communityco $base; } >/dev/null 2>&1
	if [[ ! -f $base/trunk/PKGBUILD ]]; then
		api_call update base=$base status=failed log='Check out failed'
		return
	fi

	cd $base/trunk
	setconf PKGBUILD pkgrel=0

	if [[ $base == gcc || $base == gcc-multilib ]]; then
		sed -i 's/--with-default-libstdcxx-abi=c++98//' PKGBUILD
	fi

	if [[ ${#repos[@]} -gt 1 ]]; then
		# multilib package with i686 variant
		buildcmd="build_multilib $base && build_i686 $base"
	elif [[ $repos == multilib ]]; then
		buildcmd="build_multilib $base"
	else
		buildcmd='true'
		arches=($(. PKGBUILD && printf "%s\n" "${arch[@]}" | sort | uniq))
		for arch in "${arches[@]}"; do
			case $arch in
				i686)
					buildcmd+=" && build_i686 $base"
					;;
				x86_64)
					buildcmd+=" && { build_x86_64 $base || { \
						grep -q 'error: target not found' build.log && \
						build_multilib $base cxx11abi; }; }"
					;;
			esac
		done
	fi

	echo "=> Building package $base for repos: ${repos[@]}"

	if (eval $buildcmd) > build.log 2>&1; then
		api_call update base=$base status=complete
		build_successful=1
	else
		# It would be nice to have better interrupt handling here
		# but devtools doesn't appear to handle SIGINT correctly.
		grep -q 'ERROR:.*Abort' build.log && kill -INT $$

		"$BASE_DIR"/colorstrip.pl build.log | gzip >build.log.gz
		api_call update base=$base status=failed log@build.log.gz
	fi

	rm -rf "$builddir"

	trap - EXIT INT

	popd > /dev/null
}

while :; do
	build_successful=0
	try_build
	(( $build_successful )) ||  sleep 5
done
