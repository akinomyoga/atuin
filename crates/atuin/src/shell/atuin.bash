# Include guard
if [[ ${__atuin_initialized-} == true ]]; then
    false
elif [[ $- != *i* ]]; then
    # Enable only in interactive shells
    false
elif ((BASH_VERSINFO[0] < 3 || BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 1)); then
    # Require bash >= 3.1
    [[ -t 2 ]] && printf 'atuin: requires bash >= 3.1 for the integration.\n' >&2
    false
else # (include guard) beginning of main content
#------------------------------------------------------------------------------
__atuin_initialized=true

ATUIN_SESSION=$(atuin uuid)
# shellcheck disable=SC2034
ATUIN_STTY=$(stty -g)
export ATUIN_SESSION
ATUIN_HISTORY_ID=""

export ATUIN_PREEXEC_BACKEND=$SHLVL:none
__atuin_update_preexec_backend() {
    if [[ ${BLE_ATTACHED-} ]]; then
        ATUIN_PREEXEC_BACKEND=$SHLVL:blesh-${BLE_VERSION-}
    elif [[ ${bash_preexec_imported-} ]]; then
        ATUIN_PREEXEC_BACKEND=$SHLVL:bash-preexec
    elif [[ ${__bp_imported-} ]]; then
        ATUIN_PREEXEC_BACKEND="$SHLVL:bash-preexec (old)"
    else
        ATUIN_PREEXEC_BACKEND=$SHLVL:unknown
    fi
}

__atuin_preexec() {
    # Workaround for old versions of bash-preexec
    if [[ ! ${BLE_ATTACHED-} ]]; then
        # In older versions of bash-preexec, the preexec hook may be called
        # even for the commands run by keybindings.  There is no general and
        # robust way to detect the command for keybindings, but at least we
        # want to exclude Atuin's keybindings.  When the preexec hook is called
        # for a keybinding, the preexec hook for the user command will not
        # fire, so we instead set a fake ATUIN_HISTORY_ID here to notify
        # __atuin_precmd of this failure.
        if [[ $BASH_COMMAND == '__atuin_history'* && $BASH_COMMAND != "$1" ]]; then
            ATUIN_HISTORY_ID=__bash_preexec_failure__
            return 0
        fi
    fi

    # Note: We update ATUIN_PREEXEC_BACKEND on every preexec because blesh's
    # attaching state can dynamically change.
    __atuin_update_preexec_backend

    local id
    id=$(atuin history start -- "$1")
    export ATUIN_HISTORY_ID=$id
    __atuin_preexec_time=${EPOCHREALTIME-}
}

__atuin_precmd() {
    local EXIT=$? __atuin_precmd_time=${EPOCHREALTIME-}

    [[ ! $ATUIN_HISTORY_ID ]] && return

    # If the previous preexec hook failed, we manually call __atuin_preexec
    if [[ $ATUIN_HISTORY_ID == __bash_preexec_failure__ ]]; then
        # This is the command extraction code taken from bash-preexec
        local previous_command
        previous_command=$(
            export LC_ALL=C HISTTIMEFORMAT=''
            builtin history 1 | sed '1 s/^ *[0-9][0-9]*[* ] //'
        )
        __atuin_preexec "$previous_command"
    fi

    local duration=""
    # shellcheck disable=SC2154,SC2309
    if [[ ${BLE_ATTACHED-} && ${_ble_exec_time_ata-} ]]; then
        # With ble.sh, we utilize the shell variable `_ble_exec_time_ata`
        # recorded by ble.sh.  It is more accurate than the measurements by
        # Atuin, which includes the spawn cost of Atuin.  ble.sh uses the
        # special shell variable `EPOCHREALTIME` in bash >= 5.0 with the
        # microsecond resolution, or the builtin `time` in bash < 5.0 with the
        # millisecond resolution.
        duration=${_ble_exec_time_ata}000
    elif ((BASH_VERSINFO[0] >= 5)); then
        # We calculate the high-resolution duration based on EPOCHREALTIME
        # (bash >= 5.0) recorded by precmd/preexec, though it might not be as
        # accurate as `_ble_exec_time_ata` provided by ble.sh because it
        # includes the extra time of the precmd/preexec handling.  Since Bash
        # does not offer floating-point arithmetic, we remove the non-digit
        # characters and perform the integral arithmetic.  The fraction part of
        # EPOCHREALTIME is fixed to have 6 digits in Bash.  We remove all the
        # non-digit characters because the decimal point is not necessarily a
        # period depending on the locale.
        duration=$((${__atuin_precmd_time//[!0-9]} - ${__atuin_preexec_time//[!0-9]}))
        if ((duration >= 0)); then
            duration=${duration}000
        else
            duration="" # clear the result on overflow
        fi
    fi

    (ATUIN_LOG=error atuin history end --exit "$EXIT" ${duration:+"--duration=$duration"} -- "$ATUIN_HISTORY_ID" &) >/dev/null 2>&1
    export ATUIN_HISTORY_ID=""
}

__atuin_set_ret_value() {
    return ${1:+"$1"}
}

__atuin_macro_chain_keymap=
__atuin_history() {
    if [[ $__atuin_macro_chain_keymap ]]; then
        bind -m "$__atuin_macro_chain_keymap" '"'"$__atuin_macro_chain"'": ""'
    fi

    # Default action of the up key: When this function is called with the first
    # argument `--shell-up-key-binding`, we perform Atuin's history search only
    # when the up key is supposed to cause the history movement in the original
    # binding.  We do this only for ble.sh because the up key always invokes
    # the history movement in the plain Bash.
    if [[ ${BLE_ATTACHED-} && ${1-} == --shell-up-key-binding ]]; then
        # When the current cursor position is not in the first line, the up key
        # should move the cursor to the previous line.  While the selection is
        # performed, the up key should not start the history search.
        # shellcheck disable=SC2154 # Note: these variables are set by ble.sh
        if [[ ${_ble_edit_str::_ble_edit_ind} == *$'\n'* || $_ble_edit_mark_active ]]; then
            ble/widget/@nomarked backward-line
            local status=$?
            READLINE_LINE=$_ble_edit_str
            READLINE_POINT=$_ble_edit_ind
            READLINE_MARK=$_ble_edit_mark
            return "$status"
        fi
    fi

    # READLINE_LINE and READLINE_POINT are only supported by bash >= 4.0 or
    # ble.sh.  When it is not supported, we clear them to suppress strange
    # behaviors.
    [[ ${BLE_ATTACHED-} ]] || ((BASH_VERSINFO[0] >= 4)) ||
        READLINE_LINE="" READLINE_POINT=0

    local __atuin_output
    __atuin_output=$(ATUIN_SHELL_BASH=t ATUIN_LOG=error ATUIN_QUERY="$READLINE_LINE" atuin search "$@" -i 3>&1 1>&2 2>&3)

    # We do nothing when the search is canceled.
    [[ $__atuin_output ]] || return 0

    if [[ $__atuin_output == __atuin_accept__:* ]]; then
        READLINE_LINE=${__atuin_output#__atuin_accept__:}
        READLINE_POINT=${#READLINE_LINE}

        if [[ ${BLE_ATTACHED-} ]]; then
            ble-edit/content/reset-and-check-dirty "$READLINE_LINE"
            ble/widget/accept-line
            READLINE_LINE=""
            READLINE_POINT=${#READLINE_LINE}
        elif [[ $__atuin_macro_chain_keymap ]]; then
            bind -m "$__atuin_macro_chain_keymap" '"'"$__atuin_macro_chain"'": '"$__atuin_macro_accept_line"
        fi

    else
        READLINE_LINE=$__atuin_output
        READLINE_POINT=${#READLINE_LINE}
    fi
}

__atuin_initialize_blesh() {
    # shellcheck disable=SC2154
    [[ ${BLE_VERSION-} ]] && ((_ble_version >= 400)) || return 0

    ble-import contrib/integration/bash-preexec

    # Define and register an autosuggestion source for ble.sh's auto-complete.
    # If you'd like to overwrite this, define the same name of shell function
    # after the $(atuin init bash) line in your .bashrc.  If you do not need
    # the auto-complete source by atuin, please add the following code to
    # remove the entry after the $(atuin init bash) line in your .bashrc:
    #
    #   ble/util/import/eval-after-load core-complete '
    #     ble/array#remove _ble_complete_auto_source atuin-history'
    #
    function ble/complete/auto-complete/source:atuin-history {
        local suggestion
        suggestion=$(ATUIN_QUERY="$_ble_edit_str" atuin search --cmd-only --limit 1 --search-mode prefix)
        [[ $suggestion == "$_ble_edit_str"?* ]] || return 1
        ble/complete/auto-complete/enter h 0 "${suggestion:${#_ble_edit_str}}" '' "$suggestion"
    }
    ble/util/import/eval-after-load core-complete '
        ble/array#unshift _ble_complete_auto_source atuin-history'

    # @env BLE_SESSION_ID: `atuin doctor` references the environment variable
    # BLE_SESSION_ID.  We explicitly export the variable because it was not
    # exported in older versions of ble.sh.
    [[ ${BLE_SESSION_ID-} ]] && export BLE_SESSION_ID
}
__atuin_initialize_blesh
BLE_ONLOAD+=(__atuin_initialize_blesh)
precmd_functions+=(__atuin_precmd)
preexec_functions+=(__atuin_preexec)

if [[ ${BLE_VERSION-} ]]; then
    __atuin_bind_impl() {
        local keymap=$1 keyseq=$2 widget=$3
        local command
        case $widget in
            atuin-search)          command='__atuin_history --keymap-mode=emacs' ;;
            atuin-search-viins)    command='__atuin_history --keymap-mode=vim-insert' ;;
            atuin-search-vicmd)    command='__atuin_history --keymap-mode=vim-command' ;;
            atuin-up-search)       command='__atuin_history --shell-up-key-binding --keymap-mode=emacs' ;;
            atuin-up-search-viins) command='__atuin_history --shell-up-key-binding --keymap-mode=vim-insert' ;;
            atuin-up-search-vicmd) command='__atuin_history --shell-up-key-binding --keymap-mode=vim-command' ;;
            *)
                printf '%s\n' "atuin-bind: unknown widget '$widget'" >&2
                return 2 ;;
        esac
        bind -m "$keymap" -x "\"$keyseq\": $command"
    }

else
    # To realize the enter_accept feature in a robust way, we need to call the
    # readline bindable function `accept-line'.  However, there is no way to
    # call `accept-line' from the shell script.  To call the bindable function
    # `accept-line', we utilize string macros of readline.
    #
    # For example, when we bind KEYSEQ to a WIDGET that wants to conditionally
    # call `accept-line' at the end, we perform two-step dispatching.
    #
    # 1. [KEYSEQ -> IKEYSEQ1 IKEYSEQ2]---We first translate KEYSEQ to two
    #   intermediate key sequences IKEYSEQ1 and IKEYSEQ2 using the macros.  For
    #   example, when we binds `__atuin_history` to \C-r, this step can be set
    #   up by `bind '"\C-r": "IKEYSEQ1IKEYSEQ2"'`.
    # 2. [IKEYSEQ1 -> WIDGET]---Then, IKEYSEQ1 is bound to the WIDGET, and the
    #   binding of IKEYSEQ2 is dynamically determined by WIDGET.  For example,
    #   when we binds `__atuin_history` to \C-r, this step can be set up by
    #   `bind -x '"IKEYSEQ": WIDGET'`.
    # 3. [IKEYSEQ2 -> accept-line] or [IKEYSEQ2 -> ""]---When WIDGET requests
    #   the execution of `accept-line', WIDGET can change the binding of
    #   IKEYSEQ2 by running `bind '"IKEYSEQ2": accept-line''.  Otherwise,
    #   WIDGET can change the binding of IKEYSEQ2 to no-op by running `bind
    #   '"IKEYSEQ": ""'`.
    #
    # For the choice of the intermediate key sequences, we want to choose key
    # sequences that are unlikely to conflict with others.
    #
    # * We consider the key sequences starting with \C-x.  In the emacs editing
    #   mode of Bash, \C-x is used as a prefix key, i.e., it is used for the
    #   beginning key of the keybindings with multiple keys, so \C-x is
    #   unlikely to be used for a single-key binding by the user.  Also, \C-x
    #   is not used in the vi editing mode by default.
    #
    # * For the second byte, we consider using \xC0 and \xC1.  In UTF-8
    #   encoding, these bytes are technically a part of the first byte of
    #   two-byte characters, but they never appear in the actual UTF-8 encoding
    #   because the corresponding characters have a single-byte representation.
    #   In a single-byte encoding, those are typically alphabets with accents,
    #   but I expect not many users want to define their own keybindings to C-x
    #   and letters with accents.  In the EUC (extended unix code) encoding,
    #   those bytes are the first bytes of two-byte characters.
    #
    # * For the third byte, we consider \xA0..\xA2.  In UTF-8 encoding, these
    #   bytes are used for leading bytes of the multibyte characters.  In a
    #   signle-byte encoding, they are again some alphabets.  In EUC encoding,
    #   they are used for the second byte of two-byte characters.  These third
    #   bytes are combined to our second bytes to form complete characters so
    #   that the decoder state wouldn't be broken.
    #
    # Meanwhile, we have many different widgets, where an intermediate sequence
    # should be prepared for each widget naively.
    #
    # * To minimize the number of special key sequences used by atuin, instead
    #   of specifying a widget by its own intermediate sequence, we specify a
    #   widget by a fixed-length sequence of multiple two-byte sequences.  More
    #   specifically, instead of IKEYSEQ1, we use IKS1 IKS2 IKS3 IKS4 IKS5,
    #   where IKS1..IKS4 just stores its information to a global variable, and
    #   IKS5 collects all the information and determine and call the actual
    #   widget based on the stored information. Each of IKn (n=1..5) is one of
    #   the two reserved sequences, $__atuin_macro_code0 and
    #   $__atuin_macro_code1.  For IKEYSEQ2, we use $__atuin_macro_chain.
    #   Those shell variables are defined later.

    __atuin_macro_code0='\C-x\xC0\x90'
    __atuin_macro_code1='\C-x\xC0\x91'
    __atuin_macro_chain='\C-x\xC0\x92'
    if ((BASH_VERSINFO[0] < 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3)); then
        # In bash < 4.3, "bind -x" cannot bind a shell command to a keyseq
        # having more than two bytes.  To work around this, we use the
        # following two-byte sequences in bash < 4.3.
        __atuin_macro_code0='\C-xQ'
        __atuin_macro_code1='\C-xR'
        __atuin_macro_chain='\C-xP2'
    elif ((BASH_VERSINFO[0] < 5)); then
        # In bash < 5.0, keybindings that contain 8-bit characters in the
        # second or later bytes do not work.
        __atuin_macro_code0='\C-xP0'
        __atuin_macro_code1='\C-xP1'
        __atuin_macro_chain='\C-xP2'
    fi

    # Note: In bash <= 5.0, the table for `bind -x` from the keyseq to the
    # command is shared by all the keymaps (emacs, vi-insert, and vi-command),
    # so one cannot safely bind different command strings to the same keyseq in
    # different keymaps.  Therefore, the command string and the keyseq need to
    # be globally in one-to-one correspondence in all the keymaps.
    for __atuin_keymap in emacs vi-insert vi-command; do
        bind -m "$__atuin_keymap" -x '"'"$__atuin_macro_code0"'": __atuin_macro_dispatch 0'
        bind -m "$__atuin_keymap" -x '"'"$__atuin_macro_code1"'": __atuin_macro_dispatch 1'
        bind -m "$__atuin_keymap"    '"'"$__atuin_macro_chain"'": ""'
    done
    unset -v __atuin_keymap

    if ((BASH_VERSINFO[0] >= 4)); then
        __atuin_macro_accept_line=accept-line
    else
        # Note: We rewrite the command line and invoke `accept-line'.  In bash
        # <= 3.2, there is no way to rewrite the command line from the shell
        # script, so we rewrite it using a macro and `shell-expand-line'.
        #
        # Note: Concerning the key sequences to invoke bindable functions such
        # as "\C-xP3", another option is to use "\exbegginning-of-line\r",
        # etc. to make it consistent with bash >= 5.3.  However, an older Bash
        # configuration can still conflict on [M-x].  The conflict is more
        # likely than [C-x P].
        for __atuin_keymap in emacs vi-insert vi-command; do
            bind -m "$__atuin_keymap" '"\C-xP3": beginning-of-line'
            bind -m "$__atuin_keymap" '"\C-xP4": kill-line'
            bind -m "$__atuin_keymap" '"\C-xP5": shell-expand-line'
            bind -m "$__atuin_keymap" '"\C-xP6": accept-line'
        done
        unset -v __atuin_keymap
        # shellcheck disable=SC2016
        __atuin_macro_accept_line='"\C-xP3\C-xP4$READLINE_LINE\C-xP5\C-xP6"'
    fi

    __atuin_macro_dispatch_selector=
    __atuin_macro_dispatch() {
        __atuin_macro_dispatch_selector+=$1
        ((${#__atuin_macro_dispatch_selector} < 5)) && return 0
        local s=$__atuin_macro_dispatch_selector
        __atuin_macro_dispatch_selector=${__atuin_macro_dispatch_selector:5}

        local -a __atuin_macro_keymap=(emacs vi-insert vi-command)
        local -a __atuin_atuin_keymap=(emacs vim-insert vim-command)
        local macro_keymap=${__atuin_macro_keymap[2#${s::2}]-}
        local atuin_keymap=${__atuin_atuin_keymap[2#${s:3:2}]-}
        local is_up_key_binding=${s:2:1}

        local -a argv
        argv=(__atuin_history)
        ((is_up_key_binding)) && argv+=(--shell-up-key-binding)
        [[ $atuin_keymap ]] && argv+=(--keymap-mode="$atuin_keymap")

        __atuin_macro_chain_keymap=$macro_keymap
        "${argv[@]}"
    }

    __atuin_bind_impl() {
        local keymap=$1 keyseq=$2 widget=$3
        local code0=$__atuin_macro_code0
        local code1=$__atuin_macro_code1
        local chain=$__atuin_macro_chain

        local macro=
        case $keymap in
            emacs)      macro=$code0$code0 ;;
            vi-insert)  macro=$code0$code1 ;;
            vi-command) macro=$code1$code0 ;;
            *)
                printf '%s\n' "atuin-bind: unknown keymap '$keymap'" >&2
                return 2 ;;
        esac
        case $widget in
            atuin-search)          macro+=$code0$code0$code0 ;;
            atuin-search-viins)    macro+=$code0$code0$code1 ;;
            atuin-search-vicmd)    macro+=$code0$code1$code0 ;;
            atuin-up-search)       macro+=$code1$code0$code0 ;;
            atuin-up-search-viins) macro+=$code1$code0$code1 ;;
            atuin-up-search-vicmd) macro+=$code1$code1$code0 ;;
            *)
                printf '%s\n' "atuin-bind: unknown widget '$widget'" >&2
                return 2 ;;
        esac
        macro+=$chain

        local -a argv=(bind)
        [[ $keymap ]] && argv+=(-m "$keymap")
        "${argv[@]}" "\"$keyseq\": \"$macro\""
    }
fi

atuin-bind() {
    local keymap=
    local OPTIND=1 OPTARG="" OPTERR=0 flag
    while getopts ':m:' flag "$@"; do
        case $flag in
            m) keymap=$OPTARG ;;
            *)
                printf '%s\n' "atuin-bind: unrecognized option '-$flag'" >&2
                return 2
                ;;
        esac
    done
    shift "$((OPTIND - 1))"

    if (($# != 2)); then
        printf '%s\n' 'usage: atuin-bind [-m keymap] keyseq widget' >&2
        return 2
    fi

    local keyseq=$1 widget=$2
    [[ $keymap ]] || keymap=$(bind -v | awk '$2 == "keymap" { print $3 }')
    case $keymap in
        emacs-meta) keymap=emacs keyseq='\e'$keyseq ;;
        emacs-ctlx) keymap=emacs keyseq='\C-x'$keyseq ;;
        emacs-*)    keymap=emacs ;;
        vi-insert)  ;;
        vi*)        keymap=vi-command ;;
        *)
            printf '%s\n' "atuin-bind: unknown keymap '$keymap'" >&2
            return 2 ;;
    esac

    __atuin_bind_impl "$keymap" "$keyseq" "$widget"
}

# shellcheck disable=SC2154
if [[ $__atuin_bind_ctrl_r == true ]]; then
    # Note: We do not overwrite [C-r] in the vi-command keymap because we do
    # not want to overwrite "redo", which is already bound to [C-r] in the
    # vi_nmap keymap in ble.sh.
    atuin-bind -m emacs      '\C-r' atuin-search
    atuin-bind -m vi-insert  '\C-r' atuin-search-viins
    atuin-bind -m vi-command '/'    atuin-search
fi

# shellcheck disable=SC2154
if [[ $__atuin_bind_up_arrow == true ]]; then
    atuin-bind -m emacs      '\e[A' atuin-up-search
    atuin-bind -m emacs      '\eOA' atuin-up-search
    atuin-bind -m vi-insert  '\e[A' atuin-up-search-viins
    atuin-bind -m vi-insert  '\eOA' atuin-up-search-viins
    atuin-bind -m vi-command '\e[A' atuin-up-search-vicmd
    atuin-bind -m vi-command '\eOA' atuin-up-search-vicmd
    atuin-bind -m vi-command 'k'    atuin-up-search-vicmd
fi

#------------------------------------------------------------------------------
fi # (include guard) end of main content
