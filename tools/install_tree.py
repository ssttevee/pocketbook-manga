#!/usr/bin/env python3
"""Install a generated tree while preserving runtime symlinks and file modes."""
import argparse
from pathlib import Path
import shutil
import tempfile


def install(source, destination):
    source = source.resolve()
    # Resolve parent aliases but replace a final destination symlink itself.
    destination = destination.parent.resolve() / destination.name
    if source.is_relative_to(destination) or destination.is_relative_to(source):
        raise ValueError('Installation source and destination must not overlap')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Copy completely before replacing the old output. Each installed subtree
    # is owned by this build step, so stale files from another profile disappear.
    with tempfile.TemporaryDirectory(prefix=f'.{destination.name}-install-', dir=destination.parent) as temporary:
        staging = Path(temporary) / 'new'
        previous = Path(temporary) / 'previous'
        shutil.copytree(source, staging, symlinks=True)
        if destination.exists() or destination.is_symlink():
            destination.replace(previous)
        try:
            staging.replace(destination)
        except OSError:
            if previous.exists() or previous.is_symlink():
                previous.replace(destination)
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    install(args.source, args.destination)


if __name__ == '__main__':
    main()
