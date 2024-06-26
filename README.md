## dotfiles

Your dotfiles are how you personalize your system. These are mine.
Forked from https://github.com/holman/dotfiles.git.

This was originally used on OSx, but also supports ubuntu/wsl  

## install

```sh
zsh
git clone https://github.com/gambtho/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
script/bootstrap
reload!
dot
```

This will symlink the appropriate files in `.dotfiles` to your home directory.
Everything is configured and tweaked within `~/.dotfiles`.

The main file you'll want to change right off the bat is `zsh/zshrc.symlink`,
which sets up a few paths that'll be different on your particular machine.

`dot` is a simple script that installs some dependencies, sets sane
defaults, and so on. Tweak this script, and occasionally run `dot` from
time to time to keep your environment fresh and up-to-date. You can find
this script in `bin/`.

## topical

Everything's built around topic areas. If you're adding a new area to your
forked dotfiles — say, "Java" — you can simply add a `java` directory and put
files in there. Anything with an extension of `.zsh` will get automatically
included into your shell. Anything with an extension of `.symlink` will get
symlinked without extension into `$HOME` when you run `script/bootstrap`.

## components

There's a few special files in the hierarchy.

- **bin/**: Anything in `bin/` will get added to your `$PATH` and be made
  available everywhere.
- **linux/aptfile or mac/brewfile**: This is a list of applications to install: Might want to edit this file before running any initial setup.
- **topic/\*.zsh**: Any files ending in `.zsh` get loaded into your
  environment.
- **topic/path.zsh**: Any file named `path.zsh` is loaded first and is
  expected to setup `$PATH` or similar.
- **topic/install.sh**: Any file named `install.sh` is executed when you run `script/install`. To avoid being loaded automatically, its extension is `.sh`, not `.zsh`.
- **topic/\*.symlink**: Any file ending in `*.symlink` gets symlinked into
  your `$HOME`. This is so you can keep all of those versioned in your dotfiles
  but still keep those autoloaded files in your home directory. These get
  symlinked in when you run `script/bootstrap`.

## possible todo

* remove pretzo
* https://github.com/ericmurphyxyz/dotfiles


## notes and links


* https://htr3n.github.io/2018/07/faster-zsh/
* https://blog.jonlu.ca/posts/speeding-up-zsh
* https://blog.mattclemente.com/2020/06/26/oh-my-zsh-slow-to-load/
* https://github.com/rupa/z/
* https://github.com/jenv/jenv
* https://github.com/pyenv/pyenv
* https://github.com/romkatv/zsh-bench
* https://github.com/Schniz/fnm

```
##### timer for troubleshooting
timer=$(($(gdate +%s%N)/1000000))
now=$(($(gdate +%s%N)/1000000))
elapsed=$(($now-$timer))
echo $elapsed":" $plugin
### or unncomment and run zprof
zmodload zsh/zprof
# zprof at end of file
```

```
==> benchmarking login shell of user gambtho ...
creates_tty=0
has_compsys=1
has_syntax_highlighting=0
has_autosuggestions=1
has_git_prompt=0
first_prompt_lag_ms=37.364
first_command_lag_ms=302.409
command_lag_ms=45.020
input_lag_ms=7.390
exit_time_ms=123.721
```
