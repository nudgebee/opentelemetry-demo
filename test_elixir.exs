File.open!("test_file.txt", [:read, :write, :binary], fn fd ->
  IO.inspect(fd)
  {:ok, _} = :file.position(fd, :bof)
  :ok = :file.write(fd, "test")
  :ok = :file.truncate(fd)
end)
