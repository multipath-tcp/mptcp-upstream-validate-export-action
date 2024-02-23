#! /bin/bash
#
# The goal is to validate the 'export' branch of MPTCP Upstream repo. This is
# done by building and use some static code analysis tools.
#
# In case of questions about this script, please notify Matthieu Baerts.

# We should manage all errors in this script
set -e

if [ "${INPUT_DEBUG}" = "true" ]; then
	set -x
fi

# Env vars that can be set to change the behaviour
VAL_EXP_EACH_COMMIT="${INPUT_EACH_COMMIT:-true}"
VAL_EXP_DEFCONFIG="${INPUT_DEFCONFIG:-x86_64}"
VAL_EXP_IPV6="${INPUT_IPV6:-with_ipv6}"
VAL_EXP_MPTCP="${INPUT_MPTCP:-with_mptcp}"
VAL_EXP_CHECKPATCH="${INPUT_CHECKPATCH:-false}"

export CCACHE_MAXSIZE="${INPUT_CCACHE_MAXSIZE:-5G}"

# Local vars
ERR=()
COMMITS_SKIP=()
COMMIT_ORIG_TOP_NET_NEXT="DO-NOT-MERGE: mptcp: enabled by default"
COMMIT_ORIG_BOTTOM_NET_NEXT="DO-NOT-MERGE: git markup: net-next"
COMMIT_ORIG_TOP_NET="DO-NOT-MERGE: mptcp: enabled by default (net)"
COMMIT_ORIG_BOTTOM_NET="DO-NOT-MERGE: git markup: net"
COMMIT_ORIG_TOP_TOPGIT_NET_NEXT="tgupdate: merge t/upstream base into t/upstream"
COMMIT_ORIG_TOP_FOR_REVIEW_NET_NEXT="Merge branch 't/upstream' into for-review"
COMMIT_ORIG_TOP_TOPGIT_NET="tgupdate: merge t/upstream-net base into t/upstream-net"
COMMIT_ORIG_TOP_FOR_REVIEW_NET="Merge branch 't/upstream-net' into for-review-net"
COMMIT_CURR_IS_TOP=0
COMMIT_TOP="" # filled below
COMMIT_BOTTOM="" # filled below
TMPFILE="" # filled below
KSFT_PATH="tools/testing/selftests/net/mptcp"
COMMIT_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/commit"

# Sparse
SPARSE_URL_BASE="https://mirrors.edge.kernel.org/pub/software/devel/sparse/dist/"

###########
## Utils ##
###########

COLOR_RED="\E[1;31m"
COLOR_GREEN="\E[1;32m"
COLOR_YELLOW="\E[1;33m"
COLOR_BLUE="\E[1;34m"
COLOR_RESET="\E[0m"

print_color() {
	echo -e "${*}${COLOR_RESET}"
}

print_ok() {
	print_color "${COLOR_GREEN}${*}"
}

print_info() {
	print_color "${COLOR_BLUE}${*}"
}

print_err() {
	print_color "${COLOR_RED}${*}" >&2
}

# $1: group (no space), $2: description
log_section_start() {
	echo
	echo -e "::group::${1} - ${COLOR_BLUE}${1//_/ }${COLOR_RESET}: ${COLOR_YELLOW}${2}${COLOR_RESET}"
}

# $1: group (no space)
log_section_start_commit() {
	log_section_start "${1}" "Commit: $(git log -1 --format="%h %s")"
}

log_section_end() {
	echo "::endgroup::"
	echo
}

# $@: message to display before quiting
err() {
	ERR+=("${*}")
	print_err "ERROR: ${*}"
}

# $1: variable name
invalid_input() {
	err "Invalid ${1} value: ${!1}"
}

ccache_stats() {
	log_section_start "ccache" "Show ccache stats"

	ccache -s || true

	log_section_end
}

git_get_current_commit_title() {
	git log -1 --format="format:%s" HEAD
}

# $1: commit title
git_get_sha_from_commit_title() {
	git log -1 --grep "^${1}$" --format="format:%H" "${2:-HEAD}"
}

# $1: commit title
has_commit_in_history() {
	[ -n "$(git_get_sha_from_commit_title "${1}" HEAD~99..)" ]
}

# [ $1: commit msg, default: current branch ]
is_commit_top() {
	[ "${1:-$(git_get_current_commit_title)}" = "${COMMIT_TOP}" ]
}

is_commit_top_cached() {
	[ "${COMMIT_CURR_IS_TOP}" = 1 ]
}

# args for is_commit_top
cache_commit_is_top() {
	if is_commit_top "${@}"; then
		COMMIT_CURR_IS_TOP=1
	else
		COMMIT_CURR_IS_TOP=0
	fi
}

needs_checkpatch() {
	[ "${VAL_EXP_CHECKPATCH}" = "true" ]
}

# $1: commit title
is_commit_skipped() { local commit curr
	curr="${1}"

	# We always want to validate the top commit even if it is a DO-NOT-MERGE
	if is_commit_top_cached; then
		return 1
	fi

	# No need to validate the DO-NOT-MERGE commits: either "empty" or just
	# before the top. We don't want to send them anyway
	if [[ "${curr}" = "DO-NOT-MERGE: "* ]] ||
	   [ "${curr}" = "TopGit-driven merge of branches:" ]; then
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
	git_modified_files | grep -q "^${KSFT_PATH}/"
}

commit_has_modified_selftests_sh_code() {
	git_modified_files | grep -q "^${KSFT_PATH}/.*\.sh$"
}

commit_get_modified_selftests_sh_code() {
	git_modified_files | grep "^${KSFT_PATH}/.*\.sh$"
}

commit_has_modified_mptcp_code() {
	git_modified_files | grep -q "^net/mptcp/"
}

commit_has_non_mptcp_modified_files() {
	# shellcheck disable=SC2143 ## We cannot use 'grep -q' with '-v' here
	[ -n "$(git_modified_files | \
		grep -Ev "^(net/mptcp/|${KSFT_PATH}/)")" ]
}

always_build() {
	[ "${VAL_EXP_EACH_COMMIT}" = "false" ] || is_commit_top_cached
}

get_mid() { local mid
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

# $1: status ; $2: description ; $3: category
write_results() {
	echo "$(get_mid) ${1} ${2}" | tee -a "./${3}-results.txt"
}

#################
## Init / trap ##
#################

# $1: last return code
trap_exit() { local rc error
	rc="${1}"

	# We no longer need the traces
	set +x

	rm -f "${TMPFILE}"

	# Display some stats to check everything is OK with ccache
	ccache_stats

	if [ "${rc}" -eq 0 ]; then
		if [ ${#ERR[@]} -ne 0 ]; then
			print_err "Unexpected errors found: ${ERR[*]}"
			return 1
		fi

		print_ok "Script executed with success"
		return 0
	fi

	echo -n "Last commit: "
	git log -1 --oneline --no-decorate || true

	print_err "Summary of errors:"
	for error in "${ERR[@]}"; do
		print_err "${error}"
	done

	# in the notif, only the end is displayed
	err "Script ended with an error: ${rc}"

	return "${rc}"
}

prepare() {
	trap 'trap_exit "${?}"' EXIT

	# To avoid this error:
	#   unsafe repository ('/github/workspace' is owned by someone else)
	git config --global --add safe.directory "${PWD}" || true

	# Display some stats to check everything is OK with ccache
	ccache_stats

	TMPFILE=$(mktemp)

	COMMIT_TOP="$(git_get_current_commit_title)"

	# Validate the whole export branch if we are at the top
	if [ "${COMMIT_TOP}" = "${COMMIT_ORIG_TOP_NET_NEXT}" ]; then
		COMMIT_BOTTOM="${COMMIT_ORIG_BOTTOM_NET_NEXT}"
	elif [ "${COMMIT_TOP}" = "${COMMIT_ORIG_TOP_NET}" ]; then
		COMMIT_BOTTOM="${COMMIT_ORIG_BOTTOM_NET}"
	elif has_commit_in_history "${COMMIT_ORIG_TOP_FOR_REVIEW_NET_NEXT}"; then
		# validate only commits on top of the for-review branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP_FOR_REVIEW_NET_NEXT}"
	elif has_commit_in_history "${COMMIT_ORIG_TOP_TOPGIT_NET_NEXT}"; then
		# validate only commits on top of the t/upstream branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP_TOPGIT_NET_NEXT}"
	elif has_commit_in_history "${COMMIT_ORIG_TOP_FOR_REVIEW_NET}"; then
		# validate only commits on top of the for-review-net branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP_FOR_REVIEW_NET}"
	elif has_commit_in_history "${COMMIT_ORIG_TOP_TOPGIT_NET}"; then
		# validate only commits on top of the t/upstream-net branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP_TOPGIT_NET}"
	elif has_commit_in_history "${COMMIT_ORIG_TOP_NET_NEXT}"; then
		# validate only commits on top of the export branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP_NET_NEXT}"
	elif has_commit_in_history "${COMMIT_ORIG_TOP_NET}"; then
		# validate only commits on top of the export-net branch
		COMMIT_BOTTOM="${COMMIT_ORIG_TOP_NET}"
	else
		err "Unable to find history related to MPTCP export branches"
		exit 1
	fi

	print_info "Validating commits from '${COMMIT_BOTTOM}' to '${COMMIT_TOP}'"
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

	log_section_start "sparse" "Check Sparse version"

	# Force a rebuild if a new version is available
	last=$(curl "${SPARSE_URL_BASE}" 2>/dev/null | \
		grep -o 'sparse-[0-9]\+\.[0-9]\+\.[0-9]\+\.tar' | \
		grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | \
		sort -uV | \
		tail -n1)
	# support git (vX.Y.Z-COMMITS-gSHA) and tarball versions (X.Y.Z)
	curr=$(sparse --version | cut -d- -f1 | sed 's/^v//')

	log_section_end

	if [ "${curr}" = "${last}" ]; then
		print_ok "Using the last version of Sparse: ${curr}"
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

	# For MPTCP BPF
	scripts/config -e MODULES -e BPF_JIT -e BPF_SYSCALL

	# Compile test headers exported to user-space to ensure they are
	# self-contained, i.e. compilable as standalone units.
	scripts/config -e HEADERS_INSTALL -e UAPI_HEADER_TEST

	# To avoid a prompt, stopping the tests
	scripts/config -d DEBUG_NET
}

config_mptcp() {
	if [ "${VAL_EXP_MPTCP}" = "with_mptcp" ]; then
		scripts/config -e MPTCP -e MPTCP_KUNIT_TEST
	elif [ "${VAL_EXP_MPTCP}" = "without_mptcp" ]; then
		scripts/config -d MPTCP -d MPTCP_KUNIT_TEST
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

config_new() {
	# Introduced in v5.19
	scripts/config -d DEBUG_NET
}

needs_config() {
	# we don't need the kconfig for checkpatch
	! needs_checkpatch
}

config() {
	if ! needs_config; then
		return 0
	fi

	log_section_start "config" "Set initial kernel config"

	config_base
	config_arch
	config_ipv6
	config_extras
	config_new

	make olddefconfig

	# We apply MPTCP config after because, we want to have a failure if some
	# new MPTCP options are available but we forget to enable them. We then
	# don't want to run 'make olddefconfig' after which will silently
	# disable these new options.
	config_mptcp

	log_section_end
}


###########
## Extra ##
###########

# $1: status ; $2: description
write_build_results() {
	# we need to support the "matrix" mode
	write_results "${1}" "${2}" \
		"build-${VAL_EXP_DEFCONFIG}-${VAL_EXP_IPV6}-${VAL_EXP_MPTCP}"
}

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
			# net/mptcp/protocol.h:747:20: warning: context imbalance in 'mptcp_sk_clone_init' - unexpected unlock
			if [ "$(echo "${warn}" | grep -cE "net/mptcp/protocol.[ch]:[0-9]+:[0-9]+: warning: context imbalance in 'mptcp_sk_clone(|_init)' - unexpected unlock")" -eq 1 ]; then
				print_info "Ignore the following warning because sk_clone_lock() conditionally acquires the socket lock, (if return value != 0), so we can't annotate the caller as 'release': ${warn}"
				return 0
			fi
		;;
		"net/mptcp/pm_netlink.c")
			# net/mptcp/pm_netlink.c:507:25: warning: context imbalance in 'mptcp_pm_create_subflow_or_signal_addr' - unexpected unlock
			# net/mptcp/pm_netlink.c:622:23: warning: context imbalance in 'mptcp_pm_nl_add_addr_received' - unexpected unlock
			if [ "$(echo "${warn}" | grep -cE "net/mptcp/pm_netlink.c:[0-9]+:[0-9]+: warning: context imbalance in 'mptcp_pm_create_subflow_or_signal_addr' - unexpected unlock")" -eq 1 ] || \
			   [ "$(echo "${warn}" | grep -cE "net/mptcp/pm_netlink.c:[0-9]+:[0-9]+: warning: context imbalance in 'mptcp_pm_nl_add_addr_received' - unexpected unlock")" -eq 1 ]; then
				print_info "Ignore the following warning because sparse seems fooled with the for-loop inside the unlocked part: ${warn}"
				return 0
			fi
		;;
	esac

	print_err "Non whitelisted warning: ${warn}"
	return 1
}

check_compilation_mptcp_extra_warnings() { local src obj warn rc=0
	log_section_start_commit "make_W=1_C=1"

	for src in net/mptcp/*.c; do
		obj="${src/%.c/.o}"
		if [[ "${src}" = *"_test.mod.c" ]]; then
			continue
		fi

		touch "${src}"
		if ! KCFLAGS="-Werror" make W=1 "${obj}"; then
			err "Unable to compile mptcp source code with make W=1 ${obj}"
			write_build_results "warning" "Build error with: make W=1 ${obj}"
			rc=1
		fi

		touch "${src}"
		# RC is not >0 if warn but warn are lines not starting with spaces
		while read -r warn; do
			if ! check_sparse_output "${src}" "${warn}"; then
				err "Unable to compile mptcp source code with make C=1 ${obj}: ${warn}"
				write_build_results "warning" "Build error with: make C=1 ${obj}"
				rc=1
			fi
		done <<< "$(make C=1 "${obj}" 2>&1 >/dev/null | grep "^\S")"
	done

	log_section_end

	if [ ${rc} -ne 0 ]; then
		print_err "Compilation error with make C=1 W=1"
	fi

	return "${rc}"
}


#############
## Compile ##
#############

compile_selftests() {
	log_section_start_commit "selftests"

	if ! KCFLAGS="-Werror" make -C "${KSFT_PATH}" -j"$(nproc)" -l"$(nproc)"; then
		write_build_results "fail" "Build error with: make -C ${KSFT_PATH}"
		log_section_end
		err "Unable to compile selftests"
		return 1
	fi

	log_section_end
}

compile_kernel() {
	log_section_start_commit "compilation"

	# Apply new KConfig: the first commit(s) could not support some configs:
	# these configs will then be removed from the .config file and not be
	# available later when added/modified.
	config_new

	if ! KCFLAGS="-Werror" make -j"$(nproc)" -l"$(nproc)"; then
		write_build_results "fail" "Build error with: -Werror"
		log_section_end
		err "Unable to compile the kernel"
		return 1
	fi

	log_section_end
}

check_compilation_selftests() {
	# no need to compile selftests if we didn't modify them
	if ! always_build && ! commit_has_modified_selftests_code; then
		return 0
	fi

	log_section_start_commit "headers_install"

	# make sure headers are installed
	if ! make -j"$(nproc)" -l"$(nproc)" headers_install; then
		write_build_results "fail" "Build error with: make headers_install"
		log_section_end
		err "Unable to build and install the headers"
		return 1
	fi

	log_section_end

	compile_selftests
}

check_compilation_mptcp() {
	# no need to compile with MPTCP if we didn't modify them
	if ! always_build && ! commit_has_modified_mptcp_code; then
		return 0
	fi

	compile_kernel || return ${?}

	# no need to check files in net/mptcp if they have not been modified
	check_compilation_mptcp_extra_warnings
}

check_compilation_non_mptcp() {
	# no need to compile without MPTCP if we only changed files in net/mptcp
	if ! always_build && ! commit_has_non_mptcp_modified_files; then
		return 0
	fi

	compile_kernel
}

check_compilation() {
	if [ "${VAL_EXP_MPTCP}" = "without_mptcp" ]; then
		check_compilation_non_mptcp
	elif [ "${VAL_EXP_MPTCP}" = "with_mptcp" ]; then
		check_compilation_mptcp || return ${?}
		check_compilation_selftests
	else
		invalid_input "VAL_EXP_MPTCP"
		return 1
	fi
}


################
## Checkpatch ##
################

get_commit_md() {
	git log --format=format:"[%h](${COMMIT_URL}/%H) (\`%s\`)" -1 HEAD
}

CHECKPATCH_DETAILS="./checkpatch-details.txt"
_checkpatch() {
	./scripts/checkpatch.pl \
		--strict \
		--codespell --codespellfile /usr/lib/python3/dist-packages/codespell_lib/data/dictionary.txt \
		-g HEAD 2>&1 | tee "${TMPFILE}" >&2

	{
		echo -n "- Commit $(get_commit_md):"
		if ! grep -q "^total: 0 errors, 0 warnings, 0 checks" "${TMPFILE}"; then
			echo
			echo "\`\`\`"
			cat "${TMPFILE}"
			echo "\`\`\`"
		else
			echo " no checkpatch issue"
		fi
	 } >> "${CHECKPATCH_DETAILS}"

	grep "^total:" "${TMPFILE}" | tail -n1
}

# $1: summary
get_cp_status() {
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

checkpatch() { local sum status
	log_section_start_commit "checkpatch"

	sum=$(_checkpatch)
	status=$(get_cp_status "${sum}")

	write_results "${status}" "${sum}" "checkpatch"

	log_section_end

	if [ "${status}" != "success" ]; then
		print_err "Not Checkpatch compliant: ${sum}"
	fi
}

# $1: file
SHELLCHECK_DETAILS="./shellcheck-details.txt"
_shellcheck() { local dname fname workdir
	dname="$(dirname "${1}")"
	fname="$(basename "${1}")"
	workdir="${PWD}"

	cd "${dname}"
	/usr/bin/shellcheck -x "${fname}" 2>&1 | tee "${TMPFILE}" >&2
	cd "${workdir}"

	{
		echo -n "  - ${fname}:"
		if [ -s "${TMPFILE}" ]; then
			echo
			echo "\`\`\`"
			cat "${TMPFILE}"
			echo "\`\`\`"
		else
			echo " no shellcheck issue"
		fi
	 } >> "${SHELLCHECK_DETAILS}"

	if [ -s "${TMPFILE}" ]; then
		echo "${fname}"
	fi
}

shellcheck() { local sum status ksft out
	log_section_start_commit "shellcheck"

	echo -n "- Commit $(get_commit_md):" >> "${SHELLCHECK_DETAILS}"
	if commit_has_modified_selftests_sh_code; then
		echo >> "${SHELLCHECK_DETAILS}"
		for ksft in $(commit_get_modified_selftests_sh_code); do
			out="$(_shellcheck "${ksft}")"
			if [ -n "${out}" ]; then
				sum+=" ${out}"
			fi
		done

		if [ -n "${sum}" ]; then
			status="fail"
			sum="ShellCheck issues:${sum}"
		else
			status="success"
			sum="No ShellCheck issues"
		fi
	else
		status="success"
		sum="MPTCP selftests files have not been modified"
		echo " ${sum}">> "${SHELLCHECK_DETAILS}"
	fi

	write_results "${status}" "${sum}" "shellcheck"

	log_section_end

	if [ "${status}" != "success" ]; then
		print_err "Not ShellCheck compliant: ${sum}"
	fi
}

#################
## Validations ##
#################

validate_one_commit() {
	if needs_checkpatch; then
		checkpatch
		shellcheck
	elif check_compilation; then
		write_build_results "success" "Build and static analysis OK"
	else
		return 1
	fi
}

validate_one_commit_exception() { local rc=0
	print_info "Ignoring the error, only validating the last commit"

	validate_one_commit || rc=$?

	print_err "WARNING: only one commit was validated"

	return ${rc}
}

err_no_base_commit() {
	err "Base commit has not been found (${COMMIT_BOTTOM})"

	if [ "${GITHUB_REPOSITORY_OWNER}" = "multipath-tcp" ]; then
		return 1
	fi

	validate_one_commit_exception
}

validate_each_commit() { local sha_base sha title commit rc=0
	sha_base="$(git_get_sha_from_commit_title "${COMMIT_BOTTOM}")"

	if [ -z "${sha_base}" ]; then
		err_no_base_commit
		return
	fi

	log_section_start "commits" "Validating from ${sha_base} (${COMMIT_BOTTOM}) to HEAD (${COMMIT_TOP})"
	git log --reverse --format="%h %s" "${sha_base}..HEAD"
	log_section_end

	while read -r sha title; do
		commit="${sha} ${title}"

		git checkout -q --detach -f "${sha}"

		print_info "Validating ${commit}"

		cache_commit_is_top "${title}"

		if is_commit_skipped "${title}"; then
			print_info "We can skip this commit: ${commit}"
		elif ! validate_one_commit; then
			err "Unable to validate one commit: ${commit}"
			rc=1
		fi
	done <<< "$(git log --reverse --format="%h %s" "${sha_base}..HEAD")"

	if ! is_commit_top; then
		err "Not at the top after validation: ${commit}"
		err "Was there a new kconfig option asking for confirmation?"
		return 1
	fi

	return "${rc}"
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
