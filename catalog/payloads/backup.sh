# backup <dir> [dest] - copy a directory into .backups with a timestamp.
target=$1
dest=$2
if [ -z "$target" ]; then
  echo "usage: backup <dir> [dest]"
  exit 2
fi
if [ ! -d "$target" ]; then
  echo "backup: $target: not a directory"
  exit 1
fi
if [ -z "$dest" ]; then
  dest=.backups
fi
mkdir -p "$dest"
stamp=$(date +%Y%m%d-%H%M%S)
cp -r "$target" "$dest/$target-$stamp"
echo "backed up $target -> $dest/$target-$stamp"
