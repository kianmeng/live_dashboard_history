defmodule LiveDashboardHistory do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  use GenServer
  alias Phoenix.LiveDashboard.TelemetryListener

  def metrics_history(metric, router_module) do
    GenServer.call(process_name(router_module), {:data, metric})
  end

  def start_link([metrics, buffer_size, router_module]) do
    {:ok, pid} = GenServer.start_link(__MODULE__, [metrics, buffer_size, router_module])
    Process.register(pid, process_name(router_module))
    {:ok, pid}
  end

  defp process_name(router_module), do: :"#{router_module}History"

  def init([metrics, buffer_size, router_module]) do
    GenServer.cast(self(), {:metrics, metrics, buffer_size, router_module})
    {:ok, %{}}
  end

  defp attach_handler(%{name: name_list} = metric, id, router_module) do
    :telemetry.attach(
      "#{inspect(name_list)}-history-#{id}-#{inspect(self())}",
      event(name_list),
      &__MODULE__.handle_event/4,
      {metric, router_module}
    )
  end

  defp event(name_list) do
    Enum.slice(name_list, 0, length(name_list) - 1)
  end

  def handle_event(_event_name, data, metadata, {metric, router_module}) do
    if data = TelemetryListener.prepare_entry(metric, data, metadata) do
      GenServer.cast(process_name(router_module), {:telemetry_metric, data, metric})
    end
  end

  def handle_cast({:metrics, metrics, buffer_size, router_module}, _state) do
    metric_histories_map =
      metrics
      |> Enum.with_index()
      |> Enum.map(fn {metric, id} ->
        attach_handler(metric, id, router_module)
        {metric, CircularBuffer.new(buffer_size)}
      end)
      |> Map.new()

    {:noreply, metric_histories_map}
  end

  def handle_cast({:telemetry_metric, data, metric}, state) do
    {:noreply, update_in(state[metric], &CircularBuffer.insert(&1, data))}
  end

  def handle_call({:data, metric}, _from, state) do
    if history = state[metric] do
      {:reply, CircularBuffer.to_list(history), state}
    else
      {:reply, [], state}
    end
  end
end
