defmodule Briefly.File do
  @moduledoc false

  def server do
    Process.whereis(__MODULE__) ||
      raise "could not find process Briefly.File. Have you started the :briefly application?"
  end

  use GenServer

  def start_link() do
    GenServer.start_link(__MODULE__, :ok, [name: __MODULE__])
  end

  ## Callbacks

  @max_attempts 10

  def init(:ok) do
    tmp = Briefly.Config.directory
    cwd = Path.join(File.cwd!, "tmp")
    ets = :ets.new(:briefly, [:private])
    {:ok, {[tmp, cwd], ets}}
  end

  def handle_call({:file, prefix}, {pid, _ref}, {tmps, ets} = state) do
    case find_tmp_dir(pid, tmps, ets) do
      {:ok, tmp, paths} ->
        {:reply, open(prefix, tmp, 0, pid, ets, paths), state}
      {:no_tmp, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(msg, from, state) do
    super(msg, from, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, {_, ets} = state) do
    case :ets.lookup(ets, pid) do
      [{pid, _tmp, paths}] ->
        :ets.delete(ets, pid)
        Enum.each paths, &:file.delete/1
      [] ->
        :ok
    end
    {:noreply, state}
  end

  def handle_info(msg, state) do
    super(msg, state)
  end

  ## Helpers

  defp find_tmp_dir(pid, tmps, ets) do
    case :ets.lookup(ets, pid) do
      [{^pid, tmp, paths}] ->
        {:ok, tmp, paths}
      [] ->
        if tmp = ensure_tmp_dir(tmps) do
          :erlang.monitor(:process, pid)
          :ets.insert(ets, {pid, tmp, []})
          {:ok, tmp, []}
        else
          {:no_tmp, tmps}
        end
    end
  end

  defp ensure_tmp_dir(tmps) do
    {mega, _, _} = :os.timestamp
    subdir = "/briefly-" <> i(mega)
    Enum.find_value(tmps, &write_tmp_dir(&1 <> subdir))
  end

  defp write_tmp_dir(path) do
    case File.mkdir_p(path) do
      :ok -> path
      {:error, _} -> nil
    end
  end

  defp open(prefix, tmp, attempts, pid, ets, paths) when attempts < @max_attempts do
    path = path(prefix, tmp)

    case :file.write_file(path, "", [:write, :raw, :exclusive, :binary]) do
      :ok ->
        :ets.update_element(ets, pid, {3, [path|paths]})
        {:ok, path}
      {:error, reason} when reason in [:eexist, :eaccess] ->
        open(prefix, tmp, attempts + 1, pid, ets, paths)
    end
  end

  defp open(_prefix, tmp, attempts, _pid, _ets, _paths) do
    {:too_many_attempts, tmp, attempts}
  end

  @compile {:inline, i: 1}
  defp i(integer), do: Integer.to_string(integer)

  defp path(prefix, tmp) do
    {_mega, sec, micro} = :os.timestamp
    scheduler_id = :erlang.system_info(:scheduler_id)
    tmp <> "/" <> prefix <> "-" <> i(sec) <> "-" <> i(micro) <> "-" <> i(scheduler_id)
  end

end