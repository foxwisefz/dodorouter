defmodule DodoRouter.BackgroundTask do
  @moduledoc """
  Fire-and-forget work that writes to the database.

  Under the Ecto SQL sandbox a spawned task borrows its caller's
  connection through `$callers`, but it does not inherit the caller's
  lifetime. A task that outlives the test that spawned it either dies
  mid-query — `owner #PID<...> exited / Client #PID<...> is still using a
  connection` — or can no longer find an owner at all, and any assertion
  about what it was about to write becomes a coin flip.

  So in `:test` the caller waits for the task to finish; everywhere else
  it stays detached. The work still runs in its own process either way,
  because some of it registers itself (see `DodoRouter.Evaluations`) and
  that registration has to die with the task, not with the caller.

  Because of that wait, **never start one of these from inside a
  `Repo.transaction/1`**: the caller is holding the sandbox connection
  the task needs, so in test the two would wait on each other until
  ExUnit times the test out. No current call site is in a transaction.
  """

  @doc """
  Runs `fun` in a task supervised by `supervisor`.
  """
  def start(supervisor, fun) when is_function(fun, 0) do
    supervisor |> Task.Supervisor.start_child(fun) |> settle()
  end

  @doc """
  Runs `fun` in an unsupervised task.
  """
  def start(fun) when is_function(fun, 0) do
    fun |> Task.start() |> settle()
  end

  defp settle({:ok, pid} = started) do
    if await?() do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end

    started
  end

  defp settle(other), do: other

  defp await?, do: Application.get_env(:dodo_router, :env) == :test
end
