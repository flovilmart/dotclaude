# Loads dotclaude's shell modules at nushell startup.
#
# The dotfiles installer links this file as ~/.config/nushell/autoload/00-dotclaude.nu; nushell
# sources every *.nu in that directory after config.nu, in name order, so machine-specific
# files there (e.g. 50-work.nu) load after it. A machine without ~/.claude just skips it:
# nushell ignores an autoload link whose target is missing.
# Paths are ~/.claude/..., so they don't depend on where this file is linked from.

use ~/.claude/nu/shell/linear.nu
use ~/.claude/nu/shell/inbox.nu
