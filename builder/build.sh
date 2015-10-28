#!/bin/bash

readonly API_BASE_URL=https://rebuilds.foutrelis.com
readonly AUTH_TOKEN=$(< "$HOME/.arch-rebuilds-token")
readonly VERSION=$(< "$(dirname $0)/version")
readonly BASE_DIR=$(dirname "$(readlink -f -- "$0")")

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
	staging-i686-build
}

build_x86_64() {
	staging-x86_64-build
}

build_multilib() {
	multilib-staging-build
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

	cd "$builddir"

	{ archco $base || communityco $base; } >/dev/null 2>&1
	if [[ ! -f $base/trunk/PKGBUILD ]]; then
		api_call update base=$base status=failed log='Check out failed'
		rm -rf "$builddir"
		trap - EXIT INT
		return
	fi

	cd $base/trunk
	setconf PKGBUILD pkgrel+=1
	commitcmd='svn commit -m "hdf5 1.8.15 rebuild"'

	if [[ ${#repos[@]} -gt 1 ]]; then
		# multilib package with i686 variant
		buildcmd='build_multilib && build_i686'
		commitcmd+=' && multilib-stagingpkg -a x86_64'
		commitcmd+=' && community-stagingpkg -a i686'
	elif [[ $repos == multilib ]]; then
		buildcmd='build_multilib'
		commitcmd+=' && multilib-stagingpkg'
	else
		buildcmd='true'
		arches=($(. PKGBUILD && printf "%s\n" "${arch[@]}" | sort | uniq))

		for arch in "${arches[@]}"; do
			case $arch in
				i686|any)
					buildcmd+=' && build_i686'
					;;
				x86_64)
					buildcmd+=' && { build_x86_64 || {
						grep -q "error: target not found" build.log &&
						build_multilib; }; }'
					;;
			esac
		done

		if [[ $repos == community ]]; then
			commitcmd+=' && community-stagingpkg'
		else
			commitcmd+=' && stagingpkg'
		fi
	fi

	echo "=> Building package $base for repos: ${repos[@]}"

	if (eval $buildcmd) > build.log 2>&1 && eval $commitcmd; then
		ssh nymeria.archlinux.org '/packages/db-update && /community/db-update'
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
}

# Requirements:
# - nymeria.archlinux.org mirror listed first in /etc/pacman.d/mirrorlist.
# - setconf package installed.
# - ~/.gnupg/gpg-agent.conf containing:
#     default-cache-ttl 604800
#     max-cache-ttl 604800
sanity_check() {
	if ! grep -m1 '^Server = ' /etc/pacman.d/mirrorlist | grep -F nymeria.archlinux.org >/dev/null; then
		echo 'error: must have nymeria as the first pacman mirror.' >&2
		exit 1
	fi

	if ! type -p setconf >/dev/null; then
		echo 'error: cannot find the setconf program.' >&2
		exit 1
	fi

	local option value
	for option in {default,max}-cache-ttl; do
		value=$(gpgconf --list-options gpg-agent | grep ^$option: | cut -d: -f10)
		if [[ -z $value ]]; then
			value=$(gpgconf --list-options gpg-agent | grep ^$option: | cut -d: -f8)
		fi

		if ((value < 604800)); then
			echo "error: gpg-agent option $option too low ($value) (must be at least 604800)."
			exit 1
		fi
	done
}

while sanity_check; do
	build_successful=0
	try_build
	(( $build_successful )) ||  sleep 5
done
