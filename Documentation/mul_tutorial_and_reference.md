# MuL Tutorial and Reference

MuL (pronounced **“Mule”**) is a small, structured scripting language for the
MiniRISC4 operating system. Its interpreter is inspired by
[Picol](https://github.com/antirez/picol) by Salvatore Sanfilippo; MuL credits
Picol in its [source header](../mr4src/act4/apps/mul.a4). MuL adds commands for
working with the OS console, processes, and filesystem.

MuL is intentionally small. It has variables, integer expressions, conditionals,
loops, and built-in commands, but not user-defined procedures or command
substitution.

## Tutorial

### Start MuL

Build and package the OS as usual, then start MuL from the OS shell:

```text
! MUL.PRG
```

The `MuL>` prompt accepts a command at a time. For example:

```text
MuL> puts "Hello from MuL"
Hello from MuL
MuL>
```

You can also put commands in a text file and pass its path when starting MuL:

```text
! MUL.PRG HELLO.MUL
```

MuL runs the script and exits when it reaches the end (or an `exit` command).

### Read command-line arguments

When MuL starts from the shell, argument 0 is the script path and later
arguments are the values passed after it:

```text
! MUL.PRG REPORT.MUL north 2026
```

Use `argc` to store the argument count, `argv` to store one argument in a
variable, and `args` to store the complete argument string:

```text
argc count
argv 0 script
argv 1 region
argv 2 year
args all

puts "$script $region $year"
puts "argument count: $count"
puts "all arguments: $all"
```

For `! MUL.PRG REPORT.MUL north 2026`, this prints:

```text
REPORT.MUL north 2026
argument count: 3
all arguments: REPORT.MUL north 2026
```

Arguments are separated by spaces or tabs. Argument text may include
backslash escapes and variable expansion when the MuL command line containing
`argv` is parsed.

### Store and print values

Use `set` to assign a value to a variable. Values are text; `$name` inserts a
variable's value into a command argument.

```text
set name "MiniRISC4"
puts "Hello, $name!"
```

`puts` joins its arguments with spaces and prints a newline. `incr` adds one by
default, or adds the optional amount:

```text
set count 4
incr count
incr count 5
puts "count is now $count"
```

### Simulate a small fixed array

MuL has no array type or indexing operator, but it supports dynamic scalar
names written as `$prefix$index`. Store items in variables such as `item0`,
`item1`, and `item2`, then use the index variable to read or update them:

```text
set item0 apple
set item1 banana
set item2 carrot

set index 0
while {$index < 3}
    puts $item$index
    incr index
end
```

This prints `apple`, `banana`, and `carrot`. At each pass, MuL combines
`item` with the value of `index` to look up `item0`, `item1`, or `item2`.

Change a value by generating the variable name on the left side of `set`:

```text
set index 1
set item$index cherry
puts $item$index
```

This changes slot 1 from `banana` to `cherry` and prints `cherry`.

Initialize an array by combining the loop and generated names:

```text
set index 0
while {$index < 3}
    set item$index empty
    incr index
end

set index 1
set item$index apple
puts $item$index
```

### Calculate integer expressions

`expr` evaluates an integer expression and prints its result:

```text
expr (2 + 3) * 4
expr 0x10 + 2
```

Expressions can also be used in `if` and `while` conditions. Put the expression
in braces so it is passed as one argument:

```text
set count 0
while {$count < 3}
    puts "count = $count"
    incr count
end
```

MuL uses `end` to close each block. It is not the braced-body syntax used by
Picol.

### Use conditionals and combine blocks

An optional `else` block runs when an `if` condition is false. Blocks can be
nested:

```text
set temperature 18
if {$temperature >= 20}
    puts "Warm"
else
    puts "Cool"
end
```

The following complete script demonstrates variables, arithmetic, a loop, and
a nested conditional. Save it as `COUNT.MUL` and run `! MUL.PRG COUNT.MUL`:

```text
set limit 5
set count 0
while {$count < $limit}
    if {$count == 3}
        puts "three!"
    else
        puts "count = $count"
    end
    incr count
end
puts "finished"
```

### Read input and work with files

`gets` prompts for a line from the foreground console and stores it in a
variable:

```text
gets answer
puts "You entered: $answer"
```

The OS commands let scripts inspect and modify the current working directory
and filesystem:

```text
pwd
ls
write NOTE.TXT "Created by MuL"
cat NOTE.TXT
append NOTE.TXT "Another line"
```

`write` and `append` add a newline after the text. See the command reference
below for the full OS command list.

## Language Reference

### Program and command syntax

- Each command occupies one line.
- Separate a command and its arguments with spaces or tabs.
- Double quotes (`"..."`) or braces (`{...}`) group an argument containing
  whitespace. Braces may nest; the outer braces are removed.
- `$name` expands a variable in unquoted, quoted, and braced arguments. Variable
  names contain letters, digits, or underscores. An undefined variable is an
  error; a bare `$` with no following name is literal.
- `$prefix$index` dynamically combines a literal prefix with the value of an
  index variable, then reads that scalar variable. For example, `$item$index`
  reads `item0` when `index` contains `0`. The generated name can be used on
  the left side of `set`, as in `set item$index cherry`.
- Backslash escapes `\n`, `\r`, and `\t`; any other escaped character is taken
  literally.
- A line whose first non-whitespace character is `#` is a comment.
- `if` and `while` blocks must have matching `end` lines. An `if` may have one
  `else` line before its `end`.
- Interactive input uses continuation prompts while a block is open. Entering
  a blank line at the primary prompt does nothing.

There is no command substitution: a command cannot be embedded inside another
command to produce an argument.

### Variables and output

| Command | Form | Behavior |
| --- | --- | --- |
| `set` | `set name value` | Assign text to a variable. |
| `incr` | `incr name [amount]` | Add an integer amount to a variable; omitted amount is `1`. An unset variable starts at `0`. |
| `puts` | `puts [arg ...]` | Print arguments separated by spaces, followed by a newline. |
| `gets` | `gets name` | Read a line from the foreground console into a variable. |
| `expr` | `expr expression` | Evaluate and print an integer expression. |
| `argc` | `argc name` | Store the number of startup arguments in a variable. Argument 0 is the script path. |
| `argv` | `argv index name` | Store one startup argument in a variable. |
| `args` | `args name` | Store the complete startup argument string in a variable. |
| `help` | `help` | Print the command summary. |
| `exit` | `exit [code]` | Exit MuL, optionally with a numeric exit code. |

Variables are textual, but `incr` requires the existing value and optional
amount to be integers.

### Expressions

Expressions accept decimal and `0x`/`0X` hexadecimal integer literals,
parentheses, and unary minus. Arithmetic wraps modulo 65536; division, remainder,
and comparisons use unsigned 16-bit values. Comparisons produce `1` for true
and `0` for false.

Operators are listed from highest to lowest precedence:

| Operators | Meaning |
| --- | --- |
| Unary `-` | Negation |
| `*` `/` `%` | Multiply, divide, remainder |
| `+` `-` | Add, subtract |
| `<` `<=` `>` `>=` `==` `!=` | Comparisons |
| `&&` | Logical AND |
| `||` | Logical OR |

Operators at the same precedence are evaluated left to right. Division or
remainder by zero is an expression error. Logical operators produce `0` or `1`
and do not short-circuit.

Examples:

```text
expr 2 + 3 * 4
expr (2 + 3) * 4
expr 0x20 >= 32
if {$count != 0 && $count < 10}
    puts "in range"
end
```

### Structured control flow

```text
if {expression}
    command
else
    command
end

while {expression}
    command
end
```

`else` is optional and is only valid inside an `if`. The `if`, `else`,
`while`, and `end` keywords must each be the first token on their own line.
Commands in a block are executed in order. A false `while` condition skips to
the matching `end`; a true condition repeats the body.

### OS command reference

Paths are interpreted by the OS relative to the current working directory
unless given as absolute paths.

| Command | Form | Behavior |
| --- | --- | --- |
| `pwd` | `pwd` | Print the current working directory. |
| `cd` | `cd path` | Change the current working directory. |
| `ls` | `ls [path]` | List a directory; defaults to the current directory. |
| `cat` | `cat path` | Print a file's contents. |
| `write` | `write path text...` | Write text to a file, joining text arguments with spaces and appending a newline. |
| `append` | `append path text...` | Append text to a file, joining text arguments with spaces and appending a newline. |
| `mkdir` | `mkdir path` | Create a directory. |
| `rmdir` | `rmdir path` | Remove a directory. |
| `rm` | `rm path` | Remove a file. |
| `mv` | `mv source destination` | Rename or move a file. |
| `stat` | `stat path` | Print a file's size in bytes. |
| `ps` | `ps` | List running processes. |
| `run` | `run program [args...]` | Start an OS program and print its process ID. |

The text payload for `write` and `append` is limited to 126 bytes per command.
These commands, like all MuL commands, are also subject to the source-line
length limit.

### Limits and errors

MuL uses bounded static storage:

| Resource | Limit |
| --- | ---: |
| Script or interactive input buffer | 4094 bytes |
| Lines per script | 128 |
| Bytes per line | 127 |
| Tokens per command | 12 |
| Bytes per token | 127 |
| Variables | 16 |
| Characters per variable name | 23 |
| Bytes per variable value | 127 |
| Nested `if`/`while` blocks | 16 |
| Nested active loops | 8 |

MuL prints an error when a command, expression, variable lookup, or file
operation fails. A failed command in a script marks the run as failed but does
not prevent later lines from running. Invalid or unmatched block structure
prevents the script from running. `exit` terminates the interpreter
immediately.

## Implementation Notes

MuL is a small Picol-inspired interpreter, not a full Picol port. In particular,
it uses `end` for blocks and does not implement user-defined procedures or
command substitution. The interpreter is implemented as an ACT4 userland
program and packaged as `MUL.PRG`.

For OS build and packaging details, see the
[mr4os guide](mr4os_guide.md#mul-scripting-interpreter).
