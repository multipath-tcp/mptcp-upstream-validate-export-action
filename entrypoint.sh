#! /bin/bash -x
#
# The goal is to validate the 'export' branch of MPTCP Upstream repo. This is
# done by building and use some static code analysis tools.
#
# In case of questions about this script, please notify Matthieu Baerts.

# We should manage all errors in this script
set -e

# Env vars that can be set to change the behaviour
VAL_EXP_EACH_COMMIT="${INPUT_EACH_COMMIT:-true}"
VAL_EXP_DEFCONFIG="${INPUT_DEFCONFIG:-x86_64}"
VAL_EXP_IPV6="${INPUT_IPV6:-with_ipv6}"
VAL_EXP_MPTCP="${INPUT_MPTCP:-with_mptcp}"
VAL_EXP_CHECKPATCH="${INPUT_CHECKPATCH:-false}"

export CCACHE_MAXSIZE="${INPUT_CCACHE_MAXSIZE:-5G}"

# Local vars
COMMITS_SKIP=()
COMMIT_ORIG_TOP="DO-NOT-MERGE: mptcp: enabled by default"
COMMIT_ORIG_BOTTOM="DO-NOT-MERGE: git markup: net-next"
COMMIT_TOP="" # filled below
COMMIT_BOTTOM="" # filled below
TMPFILE="" # filled below

# Sparse
SPARSE_URL_BASE="https://mirrors.edge.kernel.org/pub/software/devel/sparse/dist/"

###########
## Utils ##
###########

# $@: message to display before quiting
err() {
	echo "ERROR: ${*}" >&2
}

# $1: variable name
invalid_input() {
	err "Invalid ${1} value: ${!1}"
}

ccache_stats() {
	ccache -s || true
}

git_get_current_commit_title() {
	git log -1 --format="format:%s" HEAD
}

# $1: commit title
git_get_sha_from_commit_title() {
	git log -1 --grep "^${1}$" --format="format:%H" HEAD
}

# [ $1: commit msg, default: current branch ]
is_commit_top() {
	[ "${1:-$(git_get_current_commit_title)}" = "${COMMIT_TOP}" ]
}

needs_checkpatch() {
	[ "${VAL_EXP_CHECKPATCH}" = "true" ]
}

# $1: commit title
is_commit_skipped() { local commit curr
	curr="${1}"

	# We always want to validate the top commit even if it is a DO-NOT-MERGE
	if is_commit_top "${curr}"; then
		return 1
	fi

	# No need to validate the DO-NOT-MERGE commits: either "empty" or just
	# before the top. We don't want to send them anyway
	if [[ "${curr}" = "DO-NOT-MERGE: "* ]]; then
		return 0
	fi

	# Skip commits intentionaly introducing errors
	for commit in "${COMMITS_SKIP[@]}"; do
		if [ "${commit}" = "${curr}" ]; then
			return 0
		fi
	done

	return 1
}

git_modified_files() {
	git diff --name-only "HEAD~..HEAD"
}

commit_has_modified_selftests_code() {
	git_modified_files | grep -q "^tools/testing/selftests/net/mptcp/"
}

commit_has_modified_mptcp_code() {
	git_modified_files | grep -q "^net/mptcp/"
}

commit_has_non_mptcp_modified_files() {
	# shellcheck disable=SC2143 ## We cannot use 'grep -q' with '-v' here
	[ -n "$(git_modified_files | \
		grep -Ev "^(net/mptcp/|tools/testing/selftests/net/mptcp/)")" ]
}

each_commit() {
	[ "${VAL_EXP_EACH_COMMIT}" = "true" ]
}

#################
## Init / trap ##
#################

# $1: last return code
trap_exit() { local rc
	rc="${1}"

	# We no longer need the traces
	set +x

	rm -f "${TMPFILE}"

	# Display some stats to check everything is OK with ccache
	ccache_stats

	if [ "${rc}" -eq 0 ]; then
		echo "Script executed with success"
		return 0
	fi

	echo -n "Last commit: "
	git log -1 --oneline --no-decorate || true

	# in the notif, only the end is displayed
	err "Script ended with an error: ${rc}"

	return "${rc}"
}

prepare() {
	trap 'trap_exit "${?}"' EXIT

	# Display some stats to check everything is OK with ccache
	ccache_stats

	TMPFILE=$(mktemp)

	COMMIT_TOP="$(git_get_current_commit_title)"

	# Validate the whole export branch if we are at the top
	if [ "${COMMIT_TOP}" = "${COMMIT_ORIG_TOP}" ]; then
		COMMIT_BOTTOM="${COMMIT_ORIG_BOTTOM}"
	else # validate only commits on top of the export branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP}"
	fi
}


##########################
## Check tools versions ##
##########################

needs_sparse() {
	# we only need sparse for MPTCP code
	! needs_checkpatch && [ "${VAL_EXP_MPTCP}" = "with_mptcp" ]

}

check_sparse_version() { local last curr
	# we only need sparse for MPTCP code
	if ! needs_sparse; then
		return 0
	fi

	# Force a rebuild if a new version is available
	last=$(curl "${SPARSE_URL_BASE}" 2>/dev/null | \
		grep -o 'sparse-[0-9]\+\.[0-9]\+\.[0-9]\+\.tar' | \
		grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | \
		sort -uV | \
		tail -n1)
	curr=$(sparse --version)

	if [ "${curr}" = "${last}" ]; then
		echo "Using the last version of Sparse: ${curr}"
	else
		err "Not the last version of Sparse: ${curr} < ${last}." \
		    "Please update the Dockerfile of this action"
		return 1
	fi
}


############
## Config ##
############

config_base() {
	rm -f .config

	make tinyconfig

	scripts/config -e NET -e INET
}

config_arch() {
	if [ "${VAL_EXP_DEFCONFIG}" = "x86_64" ]; then
		scripts/config -e 64BIT
	elif [ "${VAL_EXP_DEFCONFIG}" = "i386" ]; then
		scripts/config -d 64BIT
	else
		invalid_input "VAL_EXP_DEFCONFIG"
		return 1
	fi
}

config_ipv6() {
	if [ "${VAL_EXP_IPV6}" = "with_ipv6" ]; then
		scripts/config -e IPV6
	elif [ "${VAL_EXP_IPV6}" = "without_ipv6" ]; then
		scripts/config -d IPV6
	else
		invalid_input "VAL_EXP_IPV6"
		return 1
	fi
}

config_extras() {
	# to avoid warnings/errors, enable KUnit without the tests
	scripts/config -e KUNIT \
	               -d KUNIT_ALL_TESTS

	# For INET_MPTCP_DIAG
	scripts/config -e INET_DIAG \
	               -d INET_UDP_DIAG -d INET_RAW_DIAG -d INET_DIAG_DESTROY

	# For MPTCP SYN Cookies
	scripts/config -e SYN_COOKIES

	# For TRACE_EVENT
	scripts/config -e TRACEPOINTS_ENABLED

	# Compile test headers exported to user-space to ensure they are
	# self-contained, i.e. compilable as standalone units.
	scripts/config -e HEADERS_INSTALL -e UAPI_HEADER_TEST
}

config_mptcp() {
	# MPTCP_KUNIT_TESTS has been renamed between 5.12 and 5.13
	# As long as this modification is in our tree, we need to keep both
	if [ "${VAL_EXP_MPTCP}" = "with_mptcp" ]; then
		scripts/config -e MPTCP -e MPTCP_KUNIT_TESTS -e MPTCP_KUNIT_TEST
	elif [ "${VAL_EXP_MPTCP}" = "without_mptcp" ]; then
		scripts/config -d MPTCP -d MPTCP_KUNIT_TESTS -d MPTCP_KUNIT_TEST
	else
		invalid_input "VAL_EXP_MPTCP"
		return 1
	fi

	if [ "${VAL_EXP_IPV6}" = "with_ipv6" ]; then
		scripts/config -e MPTCP_IPV6
	elif [ "${VAL_EXP_IPV6}" = "without_ipv6" ]; then
		scripts/config -d MPTCP_IPV6
	else
		invalid_input "VAL_EXP_IPV6"
		return 1
	fi
}

needs_config() {
	# we don't need the kconfig for checkpatch
	! needs_checkpatch
}

config() {
	if needs_config; then
		return 0
	fi

	config_base
	config_arch
	config_ipv6
	config_extras

	make olddefconfig

	# Here, we want to have a failure if some new MPTCP options are
	# available not to forget to enable them. We then don't want to run
	# 'make olddefconfig' which will silently disable these new options.
	config_mptcp
}


###########
## Extra ##
###########

# $1: src file ; $2: warn line
check_sparse_output() { local src warn
	src="${1}"
	warn="${2}"

	if [ -z "${warn}" ]; then
		return 0
	fi

	# ignore 'notes', only interested in the error message
	if [ "$(echo "${warn}" | \
		grep -cE "^${src}: note: in included file")" -eq 1 ]; then
		return 0
	fi

	case "${src}" in
		"net/mptcp/protocol.c")
			# net/mptcp/protocol.c:2892:24: warning: context imbalance in 'mptcp_sk_clone' - unexpected unlock
			if [ "$(echo "${warn}" | grep -cE "net/mptcp/protocol.c:[0-9]+:[0-9]+: warning: context imbalance in 'mptcp_sk_clone' - unexpected unlock")" -eq 1 ]; then
				echo "Ignore the following warning because sk_clone_lock() conditionally acquires the socket lock, (if return value != 0), so we can't annotate the caller as 'release': ${warn}"
				return 0
			fi
		;;
		"net/mptcp/pm_netlink.c")
			# net/mptcp/pm_netlink.c:507:25: warning: context imbalance in 'mptcp_pm_create_subflow_or_signal_addr' - unexpected unlock
			# net/mptcp/pm_netlink.c:622:23: warning: context imbalance in 'mptcp_pm_nl_add_addr_received' - unexpected unlock
			if [ "$(echo "${warn}" | grep -cE "net/mptcp/pm_netlink.c:[0-9]+:[0-9]+: warning: context imbalance in 'mptcp_pm_create_subflow_or_signal_addr' - unexpected unlock")" -eq 1 ] || \
			   [ "$(echo "${warn}" | grep -cE "net/mptcp/pm_netlink.c:[0-9]+:[0-9]+: warning: context imbalance in 'mptcp_pm_nl_add_addr_received' - unexpected unlock")" -eq 1 ]; then
				echo "Ignore the following warning because sparse seems fooled with the for-loop inside the unlocked part: ${warn}"
				return 0
			fi
		;;
	esac

	echo "Non whitelisted warning: ${warn}"
	return 1
}

check_compilation_mptcp_extra_warnings() { local src obj warn
	for src in net/mptcp/*.c; do
		obj="${src/%.c/.o}"
		if [[ "${src}" = *"_test.mod.c" ]]; then
			continue
		fi

		touch "${src}"
		KCFLAGS="-Werror" make W=1 "${obj}" || return 1

		touch "${src}"
		# RC is not >0 if warn but warn are lines not starting with spaces
		while read -r warn; do
			check_sparse_output "${src}" "${warn}" || return 1
		done <<< "$(make C=1 "${obj}" 2>&1 >/dev/null | grep "^\S")"
	done
}


#############
## Compile ##
#############

compile_selftests() {
	if ! KCFLAGS="-Werror" make -C tools/testing/selftests/net/mptcp -j"$(nproc)" -l"$(nproc)"; then
		err "Unable to compile selftests"
		return 1
	fi
}

compile_kernel() {
	# This is needed because we might change KConfig file in the tree: the
	# first commit(s) could support some settings, they will then be removed
	# from the .config file and not be available later when added/modified.
	config_mptcp

	if ! KCFLAGS="-Werror" make -j"$(nproc)" -l"$(nproc)"; then
		err "Unable to compile the kernel"
		return 1
	fi
}

check_compilation_selftests() {
	# no need to compile selftests if we didn't modify them
	if each_commit && ! commit_has_modified_selftests_code; then
		return 0
	fi

	# make sure headers are installed
	make -j"$(nproc)" -l"$(nproc)" headers_install || return ${?}

	compile_selftests
}

check_compilation_mptcp() {
	# no need to compile with MPTCP if we didn't modify them
	if each_commit && ! commit_has_modified_mptcp_code; then
		return 0
	fi

	compile_kernel || return ${?}

	# no need to check files in net/mptcp if they have not been modified
	if ! check_compilation_mptcp_extra_warnings; then
		err "Unable to compile mptcp source code with W=1 C=1"
		return 1
	fi
}

check_compilation_non_mptcp() {
	# no need to compile without MPTCP if we only changed files in net/mptcp
	if each_commit && ! commit_has_non_mptcp_modified_files; then
		return 0
	fi

	compile_kernel
}


################
## Checkpatch ##
################

_get_mid() { local mid
	mid=$(git log -1 --format="format:%b" | \
		grep "^Message-Id: " | \
		tail -n1 | \
		awk '{print $2}')

	if [ -n "${mid}" ]; then
		echo "${mid:1:-1}"
	else
		git rev-parse --short HEAD
	fi
}

_checkpatch() {
	./scripts/checkpatch.pl \
		--strict \
		--color=always \
		--codespell --codespellfile /usr/lib/python3/dist-packages/codespell_lib/data/dictionary.txt \
		-g HEAD 2>&1 | tee "${TMPFILE}" >&2

	grep "^total:" "${TMPFILE}" | tail -n1
}

# $1: summary
_get_pw_status() {
	case "${1}" in
		'total: 0 errors, 0 warnings, 0 checks'*)
			echo "success"
		;;
		'total: 0 errors, '*)
			echo "warning"
		;;
		*)
			echo "fail"
		;;
	esac
}

checkpatch() { local mid sum status
	mid=$(_get_mid)
	sum=$(_checkpatch)
	status=$(_get_pw_status "${sum}")

	echo "${mid} ${status} ${sum}" | tee -a "./checkpatch-results.txt"
}

#################
## Validations ##
#################

validate_one_commit() {
	if needs_checkpatch; then
		checkpatch
	elif [ "${VAL_EXP_MPTCP}" = "without_mptcp" ]; then
		check_compilation_non_mptcp
	elif [ "${VAL_EXP_MPTCP}" = "with_mptcp" ]; then
		check_compilation_mptcp || return ${?}
		check_compilation_selftests
	else
		invalid_input "VAL_EXP_MPTCP"
		return 1
	fi
}

validate_one_commit_exception() { local rc=0
	echo "Ignoring the error, only validating the last commit"

	validate_one_commit || rc=$?

	echo "WARNING: only one commit was validated"

	return ${rc}
}

err_no_base_commit() {
	err "Base commit has not been found (${COMMIT_BOTTOM})"

	if [ "${GITHUB_REPOSITORY_OWNER}" = "multipath-tcp" ]; then
		return 1
	fi

	validate_one_commit_exception
}

validate_each_commit() { local sha title sha_base commit
	sha_base="$(git_get_sha_from_commit_title "${COMMIT_BOTTOM}")"

	if [ -z "${sha_base}" ]; then
		err_no_base_commit
		return
	fi

	while read -r sha title; do
		commit="${sha} ${title}"

		git checkout --detach -f "${sha}"

		echo "Validating ${commit}"

		if is_commit_skipped "${title}"; then
			echo "We can skip this commit: ${commit}"
		elif ! validate_one_commit; then
			err "Unable to validate one commit: ${commit}"
			return 1
		fi
	done <<< "$(git log --reverse --format="%h %s" "${sha_base}..HEAD")"

	if ! is_commit_top; then
		err "Not at the top after validation: ${commit}"
		return 1
	fi
}

validation() {
	if [ "${VAL_EXP_EACH_COMMIT}" = "true" ]; then
		validate_each_commit
	elif [ "${VAL_EXP_EACH_COMMIT}" = "false" ]; then
		validate_one_commit
	else
		invalid_input "VAL_EXP_EACH_COMMIT"
		return 1
	fi
}


##########
## Main ##
##########

prepare

check_sparse_version

config

validation
