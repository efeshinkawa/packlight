import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { useEffect, useState } from "react";
import { formatMinutes, readState, send, State, switchMode } from "./lib";

/** Reads the forecast Packlight publishes every minute; the app does the measuring. */
export default function Command() {
  const [state, setState] = useState<State>();
  const [error, setError] = useState(false);

  async function reload() {
    try {
      setState(await readState());
      setError(false);
    } catch {
      setError(true);
    }
  }

  useEffect(() => {
    reload();
    const id = setInterval(reload, 5000);
    return () => clearInterval(id);
  }, []);

  if (error) {
    return (
      <List>
        <List.EmptyView
          icon={Icon.ExclamationMark}
          title="Packlight isn't running"
          actions={
            <ActionPanel>
              <Action title="Launch Packlight" icon={Icon.Play} onAction={() => send("insights")} />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  const e = state?.estimate ?? {};
  const common = (
    <>
      <Action title="Open Battery Insights" icon={Icon.LineChart} onAction={() => send("insights")} />
      {state?.mode !== "away" && <Action title="Go Away" icon={Icon.Leaf} onAction={() => switchMode("away").then(reload)} />}
      <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={reload} />
    </>
  );
  const actions = <ActionPanel>{common}</ActionPanel>;

  return (
    <List isLoading={!state}>
      <List.Section title="Now">
        <List.Item
          title="Time left"
          icon={{ source: Icon.Clock, tintColor: Color.Green }}
          accessories={[{ text: e.minutesLeft ? formatMinutes(e.minutesLeft) : e.onAC ? "On power" : "Measuring…" }]}
          actions={actions}
        />
        <List.Item
          title="Power draw"
          icon={{ source: Icon.Bolt, tintColor: (e.watts ?? 0) >= 9 ? Color.Orange : Color.Blue }}
          accessories={[{ text: e.watts ? `${e.watts.toFixed(1)} W` : "—" }]}
          actions={actions}
        />
        <List.Item
          title="Battery"
          icon={Icon.Battery}
          accessories={[
            { text: e.percent !== undefined ? `${e.percent}%` : "—" },
            { tag: e.health ? `health ${Math.round(e.health * 100)}%` : "" },
          ]}
          actions={actions}
        />
        {e.cpu !== undefined && (
          <List.Item
            title="CPU / Memory"
            icon={Icon.MemoryChip}
            accessories={[{ text: `${Math.round((e.cpu ?? 0) * 100)}% · ${(e.memUsedGB ?? 0).toFixed(1)}/${Math.round(e.memTotalGB ?? 0)} GB` }]}
            actions={actions}
          />
        )}
      </List.Section>

      {e.tips?.length ? (
        <List.Section title="Recommendations">
          {e.tips.map((t) => (
            <List.Item key={t} title={t} icon={{ source: Icon.LightBulb, tintColor: Color.Yellow }} actions={actions} />
          ))}
        </List.Section>
      ) : null}

      {e.topConsumers?.length ? (
        <List.Section title="Using the most energy">
          {e.topConsumers.map((c) => (
            <List.Item key={c} title={c} icon={Icon.Gauge} actions={actions} />
          ))}
        </List.Section>
      ) : null}
    </List>
  );
}
