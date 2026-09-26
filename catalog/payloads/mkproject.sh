# mkproject <name> - scaffold a tiny project directory.
name=$1
if [ -z "$name" ]; then
  echo "usage: mkproject <name>"
  exit 2
fi
if [ -d "$name" ]; then
  echo "mkproject: $name already exists"
  exit 1
fi
mkdir -p "$name/src"
mkdir -p "$name/tests"
echo "# $name" > "$name/README.md"
echo "created $name/ with src/ tests/ README.md"
