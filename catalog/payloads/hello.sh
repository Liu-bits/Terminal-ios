# hello [name] - greet someone. The smallest possible catalog package.
name=$1
if [ -z "$name" ]; then
  name=world
fi
echo "hello, $name"
