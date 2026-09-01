file_path = "test_file.txt"
File.write!(file_path, "initial content")

File.open!(file_path, [:read, :write, :binary], fn fd ->
  {:ok, _} = :file.position(fd, :bof)
  :ok = :file.write(fd, "new")
  :ok = :file.truncate(fd)
end)

IO.puts(File.read!(file_path))
