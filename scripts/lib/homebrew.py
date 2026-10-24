"""Where Homebrew installs a formula, shared by packaging and the license tools."""
from pathlib import Path
import re

# Homebrew keeps the upstream tarball's license and notice files at the keg root.
KEG_LICENSE_FILE = re.compile(r"^(LICENSE|LICENCE|COPYING|COPYRIGHT|NOTICE)", re.IGNORECASE)


def keg_of(source):
    """The Homebrew keg (`Cellar/<formula>/<version>`) a resolved library belongs to."""
    parts = source.parts
    if "Cellar" in parts and len(parts) > parts.index("Cellar") + 3:
        return Path(*parts[: parts.index("Cellar") + 3])
    return None
