# Include guard
[[ ${__atuin_initialized-} == true ]] && return 0
__atuin_initialized=true

# Enable only in interactive shells
[[ $- == *i* ]] || return 0

# Require bash >= 3.1
if ((BASH_VERSINFO[0] < 3 || BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 1)); then
    [[ -t 2 ]] && printf 'atuin: requires bash >= 3.1 for the integration.\n' >&2
    return 0
fi

ATUIN_SESSION=$(atuin uuid)
ATUIN_STTY=$(stty -g)
export ATUIN_SESSION
ATUIN_HISTORY_ID=""

__atuin_preexec() {
    if [[ ! ${BLE_ATTACHED-} ]]; then
        # With bash-preexec, preexec may be called even for the command run by
        # keybindings.  There is no general and robust way to detect the
        # command for keybindings, but at least we want to exclude Atuin's
        # keybindings.
        [[ $BASH_COMMAND == '__atuin_history'* && $BASH_COMMAND != "$1" ]] && return 0
    fi

    local id
    id=$(atuin history start -- "$1")
    export ATUIN_HISTORY_ID=$id
    __atuin_preexec_time=${EPOCHREALTIME-}
}

__atuin_precmd() {
    local EXIT=$? __atuin_precmd_time=${EPOCHREALTIME-}

    [[ ! $ATUIN_HISTORY_ID ]] && return

    local duration=""
    if ((BASH_VERSINFO[0] >= 5)); then
        # We use the high-resolution duration based on EPOCHREALTIME (bash >=
        # 5.0) if available.
        # shellcheck disable=SC2154,SC2309
        if [[ ${BLE_ATTACHED-} && ${_ble_exec_time_ata-} ]]; then
            # With ble.sh, we utilize the shell variable `_ble_exec_time_ata`
            # recorded by ble.sh.
            duration=${_ble_exec_time_ata}000
        else
            # With bash-preexec, we calculate the time duration here, though it
            # might not be as accurate as `_ble_exec_time_ata` because it also
            # includes the time for precmd/preexec handling.  Bash does not
            # allow floating-point arithmetic, so we remove the non-digit
            # characters and perform the integral arithmetic.  The fraction
            # part of EPOCHREALTIME is fixed to have 6 digits in Bash.  We
            # remove all the non-digit characters because the decimal point is
            # not necessarily a period depending on the locale.
            duration=$((${__atuin_precmd_time//[!0-9]} - ${__atuin_preexec_time//[!0-9]}))
            if ((duration >= 0)); then
                duration=${duration}000
            else
                duration="" # clear the result on overflow
            fi
        fi
    fi

    (ATUIN_LOG=error atuin history end --exit "$EXIT" ${duration:+"--duration=$duration"} -- "$ATUIN_HISTORY_ID" &) >/dev/null 2>&1
    export ATUIN_HISTORY_ID=""
}

__atuin_set_ret_value() {
    return ${1:+"$1"}
}

# The shell function `__atuin_evaluate_prompt` evaluates prompt sequences in
# $PS1.  We switch the implementation of the shell function
# `__atuin_evaluate_prompt` based on the Bash version because the expansion
# ${PS1@P} is only available in bash >= 4.4.
if ((BASH_VERSINFO[0] >= 5 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4)); then
    __atuin_evaluate_prompt() {
        __atuin_set_ret_value "${__bp_last_ret_value-}" "${__bp_last_argument_prev_command-}"
        __atuin_prompt=${PS1@P}

        # Note: Strip the control characters ^A (\001) and ^B (\002), which
        # Bash internally uses to enclose the escape sequences.  They are
        # produced by '\[' and '\]', respectively, in $PS1 and used to tell
        # Bash that the strings inbetween do not contribute to the prompt
        # width.  After the prompt width calculation, Bash strips those control
        # characters before outputting it to the terminal.  We here strip these
        # characters following Bash's behavior.
        __atuin_prompt=${__atuin_prompt//[$'\001\002']}

        # Count the number of newlines contained in $__atuin_prompt
        __atuin_prompt_offset=${__atuin_prompt//[!$'\n']}
        __atuin_prompt_offset=${#__atuin_prompt_offset}
    }
else
    __atuin_evaluate_prompt() {
        __atuin_prompt='$ '
        __atuin_prompt_offset=0
    }
fi

__atuin_accept_line() {
    local __atuin_command=$1

    # Reprint the prompt, accounting for multiple lines
    local __atuin_prompt __atuin_prompt_offset
    __atuin_evaluate_prompt
    local __atuin_clear_prompt
    __atuin_clear_prompt=$'\r'$(tput el)
    if ((__atuin_prompt_offset > 0)); then
        __atuin_clear_prompt+=$(
            tput cuu "$__atuin_prompt_offset"
            tput dl "$__atuin_prompt_offset"
            tput il "$__atuin_prompt_offset"
        )
    fi
    printf '%s\n' "$__atuin_clear_prompt$__atuin_prompt$__atuin_command"

    # Add it to the bash history
    history -s "$__atuin_command"

    # Assuming bash-preexec
    # Invoke every function in the preexec array
    local __atuin_preexec_function
    local __atuin_preexec_function_ret_value
    local __atuin_preexec_ret_value=0
    for __atuin_preexec_function in "${preexec_functions[@]:-}"; do
        if type -t "$__atuin_preexec_function" 1>/dev/null; then
            __atuin_set_ret_value "${__bp_last_ret_value:-}"
            "$__atuin_preexec_function" "$__atuin_command"
            __atuin_preexec_function_ret_value=$?
            if [[ $__atuin_preexec_function_ret_value != 0 ]]; then
                __atuin_preexec_ret_value=$__atuin_preexec_function_ret_value
            fi
        fi
    done

    # If extdebug is turned on and any preexec function returns non-zero
    # exit status, we do not run the user command.
    if ! { shopt -q extdebug && ((__atuin_preexec_ret_value)); }; then
        # Juggle the terminal settings so that the command can be interacted
        # with
        local __atuin_stty_backup
        __atuin_stty_backup=$(stty -g)
        stty "$ATUIN_STTY"

        # Execute the command.  Note: We need to record $? and $_ after the
        # user command within the same call of "eval" because $_ is otherwise
        # overwritten by the last argument of "eval".
        __atuin_set_ret_value "${__bp_last_ret_value-}" "${__bp_last_argument_prev_command-}"
        eval -- "$__atuin_command"$'\n__bp_last_ret_value=$? __bp_last_argument_prev_command=$_'

        stty "$__atuin_stty_backup"
    fi

    # Execute preprompt commands
    local __atuin_prompt_command
    for __atuin_prompt_command in "${PROMPT_COMMAND[@]}"; do
        __atuin_set_ret_value "${__bp_last_ret_value-}" "${__bp_last_argument_prev_command-}"
        eval -- "$__atuin_prompt_command"
    done
    # Bash will redraw only the line with the prompt after we finish,
    # so to work for a multiline prompt we need to print it ourselves,
    # then go to the beginning of the last line.
    __atuin_evaluate_prompt
    printf '%s\r%s' "$__atuin_prompt" "$(tput el)"
}

__atuin_posthook_keymap=
__atuin_history() {
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
    # ble.sh.  When it is not supported, we localize them to suppress strange
    # behaviors.
    [[ ${BLE_ATTACHED-} ]] || ((BASH_VERSINFO[0] >= 4)) ||
        local READLINE_LINE="" READLINE_POINT=0

    local __atuin_output
    __atuin_output=$(ATUIN_SHELL_BASH=t ATUIN_LOG=error atuin search "$@" -i -- "$READLINE_LINE" 3>&1 1>&2 2>&3)

    # We do nothing when the search is canceled.
    [[ $__atuin_output ]] || return 0

    if [[ $__atuin_posthook_keymap ]]; then
        bind -m "$__atuin_posthook_keymap" '"\C-x\xC0\x8d": ""'
    fi

    if [[ $__atuin_output == __atuin_accept__:* ]]; then
        __atuin_output=${__atuin_output#__atuin_accept__:}

        if [[ ${BLE_ATTACHED-} ]]; then
            ble-edit/content/reset-and-check-dirty "$__atuin_output"
            ble/widget/accept-line
        else
            if [[ $__atuin_posthook_keymap ]]; then
                READLINE_LINE=$__atuin_output
                READLINE_POINT=${#READLINE_LINE}
                bind -m "$__atuin_posthook_keymap" '"\C-x\xC0\x8d": accept-line'
                return 0
            fi
            __atuin_accept_line "$__atuin_output"
        fi

        READLINE_LINE=""
        READLINE_POINT=${#READLINE_LINE}
    else
        READLINE_LINE=$__atuin_output
        READLINE_POINT=${#READLINE_LINE}
    fi
}

# shellcheck disable=SC2154
if [[ ${BLE_VERSION-} ]] && ((_ble_version >= 400)); then
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
        suggestion=$(atuin search --cmd-only --limit 1 --search-mode prefix -- "$_ble_edit_str")
        [[ $suggestion == "$_ble_edit_str"?* ]] || return 1
        ble/complete/auto-complete/enter h 0 "${suggestion:${#_ble_edit_str}}" '' "$suggestion"
    }
    ble/util/import/eval-after-load core-complete '
        ble/array#unshift _ble_complete_auto_source atuin-history'
fi
precmd_functions+=(__atuin_precmd)
preexec_functions+=(__atuin_preexec)

if ((BASH_VERSINFO[0] > 4 || BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3)); then
    # In this implementation, when we bind KEYSEQ to a WIDGET, we first
    # translate KEYSEQ to a sequence of special codes of the form \C-x\xC0\xHH
    # (where HH is in the range 80..9F), which are denoted as [HH] hereafter in
    # this explanation.  For example, when we try to bind `atuin-search-viins'
    # to the \C-r key in the vi-insert keymap, \C-r is first translated to
    # [96][92][8d].  The process continues in the following way:
    #
    # 1. The first code [96] is used to record the current keymap in the shell
    #   variable `__atuin_posthook_keymap'.
    # 2. The second code [92] is used to perform the action corresponding to
    # ` atuin-search-viins'
    # 3. The third code [8d] is used to call the readline bindable function
    #   `accept-line' when necessary.  When we have a command to execute for
    #   the `enter_accept' feature, we rebind `accept-line' to [8d] in step 2.
    #   Otherwise, we rebind no-op to [8d] in step 2.  In this way, step 2 can
    #   control whether `accept-line' should be run.
    #
    # Note: In bash <= 5.0, the table for `bind -x` from the keyseq to the
    # command is shared by all the keymaps (emacs, vi-insert, and vi-command),
    # so one cannot safely bind different command strings to the same keyseq in
    # different keymaps.  Therefore, the command string and the keyseq need to
    # be globally in one-to-one correspondence in all the keymaps.
    for __atuin_keymap in emacs vi-insert vi-command; do
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x93": __atuin_history --keymap-mode=emacs'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x92": __atuin_history --keymap-mode=vim-insert'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x91": __atuin_history --keymap-mode=vim-normal'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x90": __atuin_history --shell-up-key-binding --keymap-mode=emacs'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x8F": __atuin_history --shell-up-key-binding --keymap-mode=vim-insert'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x8E": __atuin_history --shell-up-key-binding --keymap-mode=vim-normal'
        bind -m "$__atuin_keymap"    '"\C-x\xC0\x8D": ""'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x95": __atuin_posthook_keymap=emacs'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x96": __atuin_posthook_keymap=vi-insert'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x97": __atuin_posthook_keymap=vi-command'
        bind -m "$__atuin_keymap" -x '"\C-x\xC0\x98": __atuin_posthook_keymap='
    done
    unset -v __atuin_keymap

    __atuin_bind_dispatch_widget() {
        local target_keymap=
        case ${keymap-} in
            emacs | vi-insert | vi-command) target_keymap=$keymap ;;
            *) target_keymap=$(bind -v | awk '$2 == "keymap" { print $3 }') ;;
        esac

        local keymap_id=
        case $target_keymap in
            emacs)      keymap_id='\C-x\xC0\x95' ;;
            vi-insert)  keymap_id='\C-x\xC0\x96' ;;
            vi-command) keymap_id='\C-x\xC0\x97' ;;
            *)          keymap_id='\C-x\xC0\x98' ;;
        esac

        case $1 in
            atuin-search)          echo "$keymap_id"'\C-x\xC0\x93\C-x\xC0\x8D' ;;
            atuin-search-viins)    echo "$keymap_id"'\C-x\xC0\x92\C-x\xC0\x8D' ;;
            atuin-search-vicmd)    echo "$keymap_id"'\C-x\xC0\x91\C-x\xC0\x8D' ;;
            atuin-up-search)       echo "$keymap_id"'\C-x\xC0\x90\C-x\xC0\x8D' ;;
            atuin-up-search-viins) echo "$keymap_id"'\C-x\xC0\x8F\C-x\xC0\x8D' ;;
            atuin-up-search-vicmd) echo "$keymap_id"'\C-x\xC0\x8E\C-x\xC0\x8D' ;;
        esac
    }
else
    # In bash < 4.3, "bind -x" cannot bind a shell command to a keyseq having
    # more than two bytes.  To work around this, we first translate the keyseqs
    # to the two-byte sequences \C-x{N...S} (which are not used by default)
    # using string macros and run the shell command through the keybinding to
    # \C-x{N..S}.
    for __atuin_keymap in emacs vi-insert vi-command; do
        bind -m "$__atuin_keymap" -x '"\C-xS": __atuin_history --keymap-mode=emacs'
        bind -m "$__atuin_keymap" -x '"\C-xR": __atuin_history --keymap-mode=vim-insert'
        bind -m "$__atuin_keymap" -x '"\C-xQ": __atuin_history --keymap-mode=vim-normal'
        bind -m "$__atuin_keymap" -x '"\C-xP": __atuin_history --shell-up-key-binding --keymap-mode=emacs'
        bind -m "$__atuin_keymap" -x '"\C-xO": __atuin_history --shell-up-key-binding --keymap-mode=vim-insert'
        bind -m "$__atuin_keymap" -x '"\C-xN": __atuin_history --shell-up-key-binding --keymap-mode=vim-normal'
    done
    unset -v __atuin_keymap

    __atuin_bind_dispatch_widget() {
        case $1 in
            atuin-search)          echo '\C-xS' ;;
            atuin-search-viins)    echo '\C-xR' ;;
            atuin-search-vicmd)    echo '\C-xQ' ;;
            atuin-up-search)       echo '\C-xP' ;;
            atuin-up-search-viins) echo '\C-xO' ;;
            atuin-up-search-vicmd) echo '\C-xN' ;;
        esac
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
        printf '%s\n' 'usage: atuin-bind [-m keymap] key widget' >&2
        return 2
    fi

    local keyseq=$1 widget
    widget=$(__atuin_bind_dispatch_widget "$2")
    if [[ ! $widget ]]; then
        printf '%s\n' "atuin-bind: unknown widget '$2'" >&2
        return 2
    fi

    local -a argv=(bind)
    [[ $keymap ]] && argv+=(-m "$keymap")
    "${argv[@]}" "\"$keyseq\": \"$widget\""
}

# shellcheck disable=SC2154
if [[ $__atuin_bind_ctrl_r == true ]]; then
    # Note: We do not overwrite [C-r] in the vi-command keymap for Bash because
    # we do not want to overwrite "redo", which is already bound to [C-r] in
    # the vi_nmap keymap in ble.sh.
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
