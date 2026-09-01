File.write!("test.txt", "hello")
stat_before = File.stat!("test.txt")
File.open!("test.txt", [:write, :binary], fn fd ->
  :ok = :file.write(fd, "world")
end)
stat_after = File.stat!("test.txt")
IO.puts("Inode before: #{stat_before.inode}")
IO.puts("Inode after: #{stat_after.inode}")
