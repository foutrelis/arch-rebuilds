#!/bin/bash -e

readonly API_BASE_URL=https://rebuilds.foutrelis.com
readonly VERSION=$(< $(dirname $0)/version)

api_call() {
	local action=$1; shift
	local params=(--data-urlencode "version=$VERSION" --data-urlencode "token=$AUTH_TOKEN")

	while [[ -n $1 ]]; do
		params+=(--data-urlencode "$1")
		shift
	done

	local url="$API_BASE_URL/$action"
	local result=($(curl -s -w ' %{http_code}' -G "$url" "${params[@]}"))

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

try_build() {
	local result=($(api_call fetch))
	local restoretrap

	if [[ -z $result ]]; then
		return
	elif [[ $result != OK ]]; then
		echo "Got $result response for API call: fetch" >&2
		return
	fi

	local base=${result[1]}
	local repos=(${result[@]:2})
	local buildcmd arches arch

	restoretrap=$(trap -p EXIT)
	trap "api_call update base=$base status=pending" EXIT

	echo "Building package $base for repos: ${repos[@]}"

	archco $base || communityco $base
	pushd $base/trunk

	setconf PKGBUILD pkgrel=0

	if [[ $base == gcc || $base == gcc-multilib ]]; then
		sed -i 's/--with-default-libstdcxx-abi=c++98//' PKGBUILD
	fi

	if [[ ${#repos[@]} -gt 1 ]]; then
		# multilib package with i686 version
		buildcmd='cxx11abi-celestia-build $base cxx11abi-multilib x86_64 multilib-cxx11abi-build'
		buildcmd+=' && cxx11abi-celestia-build $base cxx11abi i686 cxx11abi-i686-build'
	elif [[ $repos == multilib ]]; then
		buildcmd='cxx11abi-celestia-build $base cxx11abi-multilib x86_64 multilib-cxx11abi-build'
	else
		buildcmd=true
		arches=($(. PKGBUILD && echo "${arch[@]}"))
		for arch in "${arches[@]}"; do
			if [[ $arch == i686 ]] || [[ $arch == x86_64 ]]; then
				buildcmd+=" && cxx11abi-celestia-build $base cxx11abi $arch cxx11abi-$arch-build"
			fi
		done
	fi

	if eval $buildcmd > >(tee stdout.log) 2> >(tee stderr.log >&2); then
		api_call update base=$base status=complete
	elif grep -q '==> ERROR:.*Abort' stdout.log stderr.log; then
		api_call update base=$base status=pending
	else
		api_call update base=$base status=failed
	fi

	popd
	rm -rf ./$base

	eval $restoretrap
}

while :; do
	try_build
	sleep 5
done
