# sum - add the integers arriving on stdin.
# usage: cat numbers.txt | sum
total=0
while read line; do
  if [ -n "$line" ]; then
    total=$(expr $total + $line)
  fi
done
echo "total: $total"
