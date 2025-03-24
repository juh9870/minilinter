#!/usr/bin/env nu

# Lint all miniscript files in the current directory
def main [--no-report (-R)] {
    run_checks
    if not $no_report {
        exit (print_issues)
    }
}

def "main watch" [--debounce-ms (-d): int = 500] {
    let run = {||
        run_checks
        print_issues
        print $"\n(date now | format date '%Y-%m-%d %H:%M:%S'): Watching ($env.PWD) for changes... \(press ctrl+c to exit\)"
    }
    do $run
    watch . --glob=**/*.ms -q -d $debounce_ms {|| 
        do $run
    }
}

# Generate (or update) a configuration file
def "main config write" [] {
    let config = load_config "./linter_config.toml" true

    $config | to toml | save ./linter_config.toml -f
}

const DEFAULT_CONFIG = {
    exclude: ['']
    abort_functions: ['qa.abort']
    rules: {
        unasserted_arguments: {
            severity: "warn"
            assert_self: false
            require_ref: true
            exceptions: ['_']
        }
        unasserted_returns: {
            severity: "warn"
            assert_self: false
            require_ref: true
        }
        missing_returns: {
            severity: "warn"
        }
        reserved_identifiers: {
            severity: "error",
            reserved: ["string", "number", "map", "list", "funcRef"]
        }
        bad_syntax: {
            severity: "error",
        }
    }
}

const SYNTAX_RESERVED_WORDS = [
    "break",
    "continue",
    "else",
    "end",
    "for",
    "function",
    "if",
    "in",
    "isa",
    "new",
    "null",
    "then",
    "repeat",
    "return",
    "while",
    "and",
    "or",
    "not",
    "true",
    "false",
    "self",
]

def run_checks [] {
    rm -f ./linter_issues.jsonl

    let config = load_config "./linter_config.toml" false

    let files = glob '(?i)./**/*.ms' --exclude $config.exclude
    for $file in $files {
        lint_file $config $file
    }
}

def load_config [file:path merge: bool] {
    if not ($file | path exists) {
        return (parse_config $DEFAULT_CONFIG)
    }

    let data = open $file
    let info = $data | describe -d

    if $info.type != record {
        print "config file must be a record"
        exit 1
    }

    if $merge {
        return (parse_config ($DEFAULT_CONFIG | merge deep $data))
    } else {
        try {
            return (parse_config $data)
        } catch {
            let filename = $env.CURRENT_FILE | path basename
            print $"(ansi red)Failed to parse config file(ansi reset)\nHelp: if you just updated the linter, you may need to run `(ansi attr_bold)($filename) config write(ansi reset)` to update the config file"
            exit 1
        }
    }
}

def parse_config [data: record<exclude: list<string>, abort_functions: list<string>, rules: record<unasserted_arguments: record<severity: string, assert_self: bool, require_ref: bool, exceptions: list<string>>, unasserted_returns: record<severity: string, assert_self: bool, require_ref: bool>, missing_returns: record<severity: string>, reserved_identifiers: record<severity: string, reserved: list<string>>, bad_syntax: record<severity: string>>>] {
    return $data
}

const INTERNAL = "internal"
const WARN = "warn"
const ERROR = "error"

def lint_file [config: record, issues_file: path] {
    let content = open $issues_file --raw

    let lines = $content | lines | each { str trim }
    mut allows: list<string> = []

    for row in ($lines | enumerate) {
        let i = $row.index
        let line = $row.item

        check_assignment $config $lines $i $line $issues_file $allows
        check_funcdef $config $lines $i $line $issues_file $allows
        check_returns $config $lines $i $line $issues_file $allows
        check_missing_returns $config $lines $i $line $issues_file $allows

        # check for allows
        let allow = $line | parse -r '^\/\/\s*@allow\s+(?<code>\S+)'
        if ($allow | is-not-empty) {
            let code = $allow | get 0.code | str trim
            if not ($code | is-empty) {
                $allows = $allows | append $code
            }
        } else {
            $allows = []
        }
    }
}

const QA_ASSERT_REGEX = '^qa.assert';
const QA_VARNAME_REGEX = '^qa.assert(?:\w+)?\s*\(?\s*';
const QA_REF_VARNAME_REGEX = $QA_VARNAME_REGEX + '@\s*';
const RETURN_REGEX = '^return'
const RETURN_VARIABLE_REGEX = '^return\s*(?:@\s*)?(?<varname>\w+)$'
const RETURN_REF_VARIABLE_REGEX = '^return\s*@\s*(?<varname>\w+)$'
const ASSIGNMENT_REGEX = '^(?:(?:locals|globals|outer)\s*\.\s*)?(?<varname>\w+)\s*='
const ARRAY_ASSIGNMENT_REGEX = '^(?:locals|globals|outer)\s*\[\s*\"(?<varname>\w+)\"\s*\]\s*='

def check_assignment [config: record, lines: list<string>, i: int, line: string, issues_file: path, allows: list<string>] {
    let assignment_data = $line | parse -r $ASSIGNMENT_REGEX

    let varname: string = if ($assignment_data | is-not-empty) {
        $assignment_data | get 0.varname | str trim
    } else {
        let array_assignment_data = $line | parse -r $ARRAY_ASSIGNMENT_REGEX
        if ($array_assignment_data | is-empty) {
            return
        } else {
            $array_assignment_data | get 0.varname | str trim
        }
    }

    if $varname in $config.rules.reserved_identifiers.reserved {
        let code = $"reserved_identifiers\(($varname)\)"
        if $code not-in $allows {
            report_issue $issues_file $i $"variable `($varname)` is a reserved identifier" $code $config.rules.reserved_identifiers.severity
        }
    }
    if $varname in $SYNTAX_RESERVED_WORDS {
        let code = $"bad_syntax.reserved_keyword_assignment\(($varname)\)"
        report_issue $issues_file $i $"cannot assign to a syntax reserved keyword `($varname)`" $code $config.rules.bad_syntax.severity
    }
}

def check_funcdef [config: record, lines: list<string>, i: int, line: string, issues_file: path, allows: list<string>] {
    const fn_regex = 'function\s*\(\s*(?<args>[^)]+?)\s*\)'
    const args_regex = '(?<argname>\w+)(?:\s*=[^,]*)?'

    # Check for unasserted arguments
    let funcdef = $line | parse -r $fn_regex
    if ($funcdef | is-empty) {
        return
    }

    let args = $funcdef | get 0.args | str trim
    if ($args | is-empty) {
        return
    }

    let argnames: string = $args | parse -r $args_regex | get argname | each {|name| $name | str trim}

    # arguments should be preset at this point
    if ($argnames | is-empty) {
        report_issue $issues_file $i "function definition has arguments but they could not be parsed" "internal" $INTERNAL
        return
    }
    
    for $arg in $argnames {
        # argument name should also not be empty
        if ($arg | is-empty) {
            report_issue $issues_file $i "function definition on has an empty argument" "internal" $INTERNAL
        }

        if ($arg != "self") and ($arg in $SYNTAX_RESERVED_WORDS) {
            let code = $"bad_syntax.reserved_keyword_as_argument\(($arg)\)"
            report_issue $issues_file $i $"cannot use syntax reserved keyword `($arg)` as a function argument" $code $config.rules.bad_syntax.severity
        }
        if $arg in $config.rules.reserved_identifiers.reserved {
            let code = $"reserved_identifiers\(($arg)\)"

            if $code not-in $allows {
                report_issue $issues_file $i $"argument `($arg)` is a reserved identifier" $code $config.rules.reserved_identifiers.severity
            }
        }


        # check if argument is in exceptions
        if $arg in $config.rules.unasserted_arguments.exceptions {
            continue
        }

        # check if argument is self
        if ((not $config.rules.unasserted_arguments.assert_self) and ($arg == "self")) {
            continue
        }

        # check function body for assertions
        for j in ($i + 1).. {
            let line = $lines | get $j
            if ($line | is-meaningless) {
                continue
            }

            # No need to check further if we hit an abort
            if ($line | is-abort $config) {
                break
            }

            if $line !~ $QA_ASSERT_REGEX {
                let code = $"unasserted_arguments\(($arg)\)"
                if $code not-in $allows {
                    report_issue $issues_file $j $"argument `($arg)` is not type-checked" $code $config.rules.unasserted_arguments.severity
                }
                break
            }
            if $line =~ ($QA_REF_VARNAME_REGEX + $arg) {
                # match found
                break
            }

            if $line =~ ($QA_VARNAME_REGEX + $arg) {
                # match found, but not a reference
                if $config.rules.unasserted_arguments.require_ref {
                    let code = $"unasserted_arguments.not_by_ref\(($arg)\)"
                    if $code not-in $allows {
                        report_issue $issues_file $j $"argument `($arg)` is not type-checked by reference" $code $config.rules.unasserted_arguments.severity $"change invocation to use variable by reference: @($arg)"
                    }
                }
                break
            }
        }
    }
}

def check_returns [config: record, lines: list<string>, i: int, line: string, issues_file: path, allows: list<string>] {
    if $line !~ $RETURN_REGEX {
        return
    }
    let return_data = $line | parse -r $RETURN_VARIABLE_REGEX
    if ($return_data | is-empty) {
        let code = $"unasserted_returns.not_a_variable"
        if $code not-in $allows {
            report_issue $issues_file $i $"return statement is not a plain variable return" $code $config.rules.unasserted_returns.severity
        }
        return
    }

    let varname: string = $return_data | get 0.varname | str trim

    if ($varname | is-empty) {
        report_issue $issues_file $i "return statement has no variable" "internal" $INTERNAL
        return
    }

    if $varname == "null" {
        return
    }

    if (not $config.rules.unasserted_returns.assert_self) and ($varname == "self") {
        return
    }

    if $line !~ $RETURN_REF_VARIABLE_REGEX {
        if $config.rules.unasserted_returns.require_ref {
            let code = $"unasserted_returns.return_not_by_ref\(($varname)\)"
            if $code not-in $allows {
                report_issue $issues_file $i $"variable `($varname)` is not returned by reference" $code $config.rules.unasserted_returns.severity $"change return to use variable by reference: @($varname)"
            }
        }
    }

    for j in (0..($i - 1) | each {} | reverse) {
        let line = $lines | get $j
        if ($line | is-meaningless) {
            continue
        }

        # No need to check further if we hit an abort
        if ($line | is-abort $config) {
            break
        }

        if $line !~ $QA_ASSERT_REGEX {
            let code = $"unasserted_returns\(($varname)\)"
            if $code not-in $allows {
                report_issue $issues_file $i $"return variable `($varname)` is not type-checked" $code $config.rules.unasserted_returns.severity
            }
            break
        }

        if $line =~ ($QA_REF_VARNAME_REGEX + $varname) {
            # match found
            break
        }

        if $line =~ ($QA_VARNAME_REGEX + $varname) {
            # match found, but not a reference
            if $config.rules.unasserted_arguments.require_ref {
                let code = $"unasserted_returns.not_by_ref\(($varname)\)"
                if $code not-in $allows {
                    report_issue $issues_file $j $"return variable `($varname)` is not type-checked by reference" $code $config.rules.unasserted_returns.severity $"change invocation to use variable by reference: @($varname)"
                }
            }
            break
        }
    }
}

def check_missing_returns [config: record, lines: list<string>, i: int, line: string, issues_file: path, allows: list<string>] {
    if $line != "end function" {
        return
    }

    for j in (0..($i - 1) | each {} | reverse) {
        let line = $lines | get $j
        if ($line | is-meaningless) {
            continue
        }

        # No need to check further if we hit an abort
        if ($line | is-abort $config) {
            break
        }

        if $line !~ $RETURN_REGEX {
            let code = "missing_returns"
            if $code not-in $allows {
                report_issue $issues_file $j "function is missing a closing return statement" $code $config.rules.missing_returns.severity
            }
        }
        break
    }
}

def report_issue [file: path, line: int, message: string, code: string, severity: string, help?: string] {
    (({ file: $file, line: ($line + 1), message: $message, severity: $severity, code: $code, help: $help } | to json -r) + "\n") | save -a ./linter_issues.jsonl
}

def print_issues [] {
    let allIssues = if ("./linter_issues.jsonl" | path exists) { open ./linter_issues.jsonl | from json --objects } else { [] }
    if ($allIssues | is-not-empty) {
        let widths = $allIssues | update cells { to text | str length } | math max | update line { |it| $it.line + 1 }
        let files = $allIssues | group-by file --to-table
        for entry in $files {
            let file = $entry.file
            let issues = $entry.items | reject file
            print $"(ansi attr_bold)($file)(ansi reset)"
            for $issue in $issues {
                let lineText = ($issue.line | to text) + ":"
                let severityText = match $issue.severity {
                    "error" => $"(ansi red)($issue.severity)(ansi reset)"
                    "warn" => $"(ansi yellow)($issue.severity)(ansi reset)"
                    "internal" => $"(ansi purple)($issue.severity)(ansi reset)"
                    _ => $issue.severity
                }
                let codeText = $"(ansi attr_dimmed)($issue.code)(ansi reset)"
                print ("    " + (format_row $widths { line: $lineText severity: $severityText message: $issue.message code: $codeText } "  "))
                if $issue.help != null {
                    print ("      Help: " + $issue.help)
                }
            }
            print ""
        }
    }
    let warnsCount = ($allIssues | where severity == "warn" | length)
    let errorsCount = ($allIssues | where {|it| $it.severity == "error" or $it.severity == "internal"} | length)
    let issuesCount = $allIssues | length
    if $issuesCount == 0 {
        print $"(ansi green)No issues found(ansi reset)"
        return 0
    } else {
        if $errorsCount > 0 {
            print $"(ansi red)✖ ($issuesCount) problems \(($errorsCount) errors, ($warnsCount) warnings\)(ansi reset)"
            return 1
        } else {
            print $"(ansi yellow_bold)!(ansi reset)(ansi yellow) ($issuesCount) problems \(($errorsCount) errors, ($warnsCount) warnings\)(ansi reset)"
            return 0
        }
    }
}

def format_row [widths: record, entries: record, separator: string] {
    $entries | items {|k,v| $v | fill -a left -c ' ' -w ($widths | get $k) } | str join $separator
}

def is-meaningless []: string -> bool {
  return (($in | is-empty) or ($in | str starts-with "//"))
}

def is-abort [config: record]: string -> bool {
    let line = $in
    return ($config.abort_functions | any {|it| $line | str starts-with $it })
}

export def 'merge deep' [other: any]: any -> any {
  let self = $in
  def type [] { describe | split row < | get 0 }
  match [($self | type) ($other | type)] {
    [record record] => { merge record $self $other }
    [list list] => { merge list $self $other }
    [_ nothing] => $self
    _ => $other
  }
}

def 'merge record' [self: record other: record]: nothing -> record {
  let keys = ($self | columns) ++ ($other | columns) | uniq
  let table = $keys | par-each { |key|
    alias value = get --ignore-errors $key
    { key: $key val: ($self | value | merge deep ($other | value)) }
  }
  $table | transpose --header-row --as-record
}

def 'merge list' [self: list other: list]: nothing -> list {
    $self ++ ($other | where {|it| $it not-in $self})
}