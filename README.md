# Minilinter

An extremely pedantic linter for MiniScript.

The goal of the project is to provide a linter that enforces a set of very strict rules to minimize the amount of type mismatches, which is by far the most common issue I encounter when working with MiniScript.

## Requirements
Nushell is required to run this script. You can install it from [nushell.sh](https://www.nushell.sh/)

## Usage
A basic usage is to just run it with the default settings. This will lint all the files in the current directory and its subdirectories.
```sh
$ ./linter.nu
```

or on windows
```cmd
> nu ./linter.nu
```

You can also configure the linter. To do so, initialize config with the following command:
```sh
$ ./linter.nu config write
```

This will create an editable configuration file `linter_config.toml` in the current directory. You can edit it to your liking.

Alternatively, download the `linter_config.toml` from this repository and edit it.

## Configuration
Check the [./linter_config.toml](./linter_config.toml) file for the default configuration and explanations.

## Rules
### `unasserted_arguments`
Makes linter check that for every function argument, there is a `qa.assert argname` at the start of a function.

> Actually it supports any function that starts with `assert` in QA, so you can define a custom `qa.assertType` and it would be recognized

### `unasserted_returns`
Makes the linter check for every function return value to be in form of `return varname` and that the `varname` is asserted one line prior

### `missing_returns`
Checks that every function has a return statement right before `end function`

### `reserved_identifiers`
Checks for assignments to or usage as function argument of a list of reserved identifiers

The default list consists of identifiers that are used for intrinsic classes in MiniScript, which cause confusing and hard to debug errors when shadowed

### `bad_syntax`
Checks for a subset of syntax errors that are common in MiniScript

There is no good reason to disable this rule, as any constructs matched by it are already syntax errors or guaranteed irrecoverable runtime errors