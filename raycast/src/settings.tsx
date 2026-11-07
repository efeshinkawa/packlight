import { Action, ActionPanel, Color, Form, Icon, List, showToast, Toast, useNavigation } from "@raycast/api";
import { existsSync } from "fs";
import { useCallback, useEffect, useState } from "react";
import { readState, send, setSetting, State, switchMode } from "./lib";

const TOGGLES: { section: string; items: [key: string, title: string][] }[] = [
  {
    section: "Automatic",
    items: [["autoSwitch", "Away when unplugged, Home when plugged in"]],
  },
  {
    section: "When going Away",
    items: [
      ["quitApps", "Quit heavy apps"],
      ["shutdownSims", "Shut down simulators"],
      ["killDev", "Stop build and dev-server processes"],
      ["stopBrew", "Stop brew services (restarted at Home)"],
    ],
  },
  {
    section: "Cleanup",
    items: [
      ["clearDerivedData", "Xcode DerivedData"],
      ["clearSimCaches", "Simulator caches"],
      ["clearXcodeCaches", "Xcode caches"],
      ["clearNpm", "npm cache"],
      ["brewCleanup", "brew cleanup"],
      ["purgeRAM", "Free inactive RAM (purge)"],
    ],
  },
];

const LANGS: [code: string, name: string][] = [
  ["system", "System"],
  ["en", "English"],
  ["tr", "Türkçe"],
  ["es", "Español"],
  ["zh-Hans", "简体中文"],
  ["hi", "हिन्दी"],
  ["ar", "العربية"],
  ["fr", "Français"],
  ["pt-BR", "Português (Brasil)"],
  ["de", "Deutsch"],
  ["ja", "日本語"],
  ["ru", "Русский"],
  ["ko", "한국어"],
];

const POLICIES: [value: string, label: string][] = [
  ["away", "With Away mode"],
  ["battery", "Whenever on battery"],
  ["below", "When battery is low"],
  ["never", "Never"],
];

const SUDOERS = "/etc/sudoers.d/packlight";

const TEXTS: [key: string, title: string, hint: string][] = [
  ["relaunchApps", "Close while away, reopen at home", "Bundle IDs, comma separated (e.g. com.logi.ghub)"],
  ["appBundleIDs", "Apps to quit when going Away", "Bundle IDs, comma separated"],
  ["extraPatterns", "Extra process patterns", "Regex, comma separated"],
];

export default function Command() {
  const [state, setState] = useState<State>();
  const [error, setError] = useState<string>();
  const [privileged, setPrivileged] = useState(existsSync(SUDOERS));

  const reload = useCallback(async () => {
    try {
      setState(await readState());
      setPrivileged(existsSync(SUDOERS));
      setError(undefined);
    } catch {
      setError("Packlight isn't running or hasn't been opened yet.");
    }
  }, []);

  useEffect(() => {
    reload();
  }, [reload]);

  async function update(key: string, value: boolean | number | string) {
    await setSetting(key, value);
    // Optimistic, then confirm from the app.
    setState((s) => (s ? { ...s, settings: { ...s.settings, [key]: value } } : s));
    setTimeout(reload, 600);
  }

  async function changeMode(mode: "home" | "away") {
    const toast = await showToast({ style: Toast.Style.Animated, title: mode === "away" ? "Going Away…" : "Going Home…" });
    const msg = await switchMode(mode);
    toast.style = Toast.Style.Success;
    toast.title = msg;
    reload();
  }

  if (error) {
    return (
      <List>
        <List.EmptyView
          icon={Icon.ExclamationMark}
          title={error}
          description="Press Enter to launch it"
          actions={
            <ActionPanel>
              <Action
                title="Launch Packlight"
                icon={Icon.Play}
                onAction={async () => {
                  await send("cancel");
                  setTimeout(reload, 1500);
                }}
              />
            </ActionPanel>
          }
        />
      </List>
    );
  }

  const s = state?.settings ?? {};
  const isAway = state?.mode === "away";
  const grace = Number(s.graceSeconds ?? 30);

  return (
    <List isLoading={!state} searchBarPlaceholder="Search settings…">
      <List.Section title="Mode">
        <List.Item
          title={isAway ? "Away mode" : "Home mode"}
          subtitle={isAway ? "Light and quiet" : "Full power, builds welcome"}
          icon={{ source: isAway ? Icon.Leaf : Icon.House, tintColor: isAway ? Color.Green : Color.Orange }}
          accessories={[{ tag: { value: "active", color: isAway ? Color.Green : Color.Orange } }]}
          actions={
            <ActionPanel>
              <Action
                title={isAway ? "Go Home" : "Go Away"}
                icon={isAway ? Icon.House : Icon.Leaf}
                onAction={() => changeMode(isAway ? "home" : "away")}
              />
              <Action
                title="Cancel Pending Switch"
                icon={Icon.XMarkCircle}
                onAction={() => send("cancel")}
              />
              <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={reload} />
            </ActionPanel>
          }
        />
        {state?.lastReport.length ? (
          <List.Item
            title="Last run"
            subtitle={state.lastReport.join(" · ")}
            icon={Icon.CheckCircle}
            accessories={state.lastReportDate ? [{ date: state.lastReportDate }] : []}
          />
        ) : null}
      </List.Section>

      <List.Section title="Automatic switching">
        {TOGGLES[0].items.map(([key, title]) => toggleItem(key, title))}
        <List.Item
          title="Wait after unplugging"
          icon={Icon.Clock}
          accessories={[{ text: `${grace} s` }]}
          actions={
            <ActionPanel>
              {[0, 10, 30, 60, 120, 300].map((v) => (
                <Action key={v} title={v === 0 ? "Immediately" : `${v} s`} icon={v === grace ? Icon.Checkmark : Icon.Clock} onAction={() => update("graceSeconds", v)} />
              ))}
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="Low Power Mode">
        <List.Item
          title="Turn on"
          icon={Icon.Battery}
          accessories={[{ text: POLICIES.find(([v]) => v === String(s.lowPowerPolicy ?? "away"))?.[1] ?? "With Away mode" }]}
          actions={
            <ActionPanel>
              {POLICIES.map(([value, label]) => (
                <Action key={value} title={label} icon={value === String(s.lowPowerPolicy ?? "away") ? Icon.Checkmark : Icon.Battery} onAction={() => update("lowPowerPolicy", value)} />
              ))}
            </ActionPanel>
          }
        />
        {String(s.lowPowerPolicy) === "below" && (
          <List.Item
            title="Battery below"
            icon={Icon.BatteryCharging}
            accessories={[{ text: `${Number(s.lowPowerThreshold ?? 30)}%` }]}
            actions={
              <ActionPanel>
                {[10, 20, 30, 40, 50].map((v) => (
                  <Action key={v} title={`${v}%`} icon={v === Number(s.lowPowerThreshold ?? 30) ? Icon.Checkmark : Icon.Circle} onAction={() => update("lowPowerThreshold", v)} />
                ))}
              </ActionPanel>
            }
          />
        )}
        {toggleItem("lowPowerOffAtHome", "Turn off when plugged in")}
      </List.Section>

      {TOGGLES.slice(1).map((group) => (
        <List.Section key={group.section} title={group.section}>
          {group.items.map(([key, title]) => toggleItem(key, title))}
        </List.Section>
      ))}

      <List.Section title="System">
        <List.Item
          title="Password-free helper (Low Power + RAM purge)"
          icon={{ source: privileged ? Icon.Shield : Icon.ExclamationMark, tintColor: privileged ? Color.Green : Color.Orange }}
          accessories={[{ tag: { value: privileged ? "Installed" : "Not installed", color: privileged ? Color.Green : Color.Orange } }]}
          actions={
            <ActionPanel>
              <Action
                title="Install Password-Free Helper"
                icon={Icon.Shield}
                onAction={async () => {
                  await send("install-privileges");
                  await showToast({ style: Toast.Style.Success, title: "Check the password prompt" });
                  setTimeout(() => setPrivileged(existsSync(SUDOERS)), 8000);
                }}
              />
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="App">
        <List.Item
          title="Language"
          icon={Icon.Globe}
          accessories={[{ text: LANGS.find(([c]) => c === String(s.language ?? "system"))?.[1] ?? "System" }]}
          actions={
            <ActionPanel>
              {LANGS.map(([code, name]) => (
                <Action key={code} title={name} icon={code === String(s.language ?? "system") ? Icon.Checkmark : Icon.Globe} onAction={() => update("language", code)} />
              ))}
            </ActionPanel>
          }
        />
        <List.Item
          title="Open Settings Window"
          icon={Icon.Gear}
          actions={
            <ActionPanel>
              <Action title="Open in Packlight" icon={Icon.AppWindow} onAction={() => send("settings")} />
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="Lists">
        {TEXTS.map(([key, title, hint]) => (
          <List.Item
            key={key}
            title={title}
            subtitle={String(s[key] ?? "") || "—"}
            icon={Icon.Pencil}
            actions={
              <ActionPanel>
                <Action.Push
                  title="Edit"
                  icon={Icon.Pencil}
                  target={<EditText title={title} hint={hint} value={String(s[key] ?? "")} onSave={(v) => update(key, v)} />}
                />
              </ActionPanel>
            }
          />
        ))}
      </List.Section>
    </List>
  );

  function toggleItem(key: string, title: string) {
    const on = s[key] === true || s[key] === 1;
    return (
      <List.Item
        key={key}
        title={title}
        icon={{ source: on ? Icon.CheckCircle : Icon.Circle, tintColor: on ? Color.Green : Color.SecondaryText }}
        accessories={[{ tag: { value: on ? "On" : "Off", color: on ? Color.Green : Color.SecondaryText } }]}
        actions={
          <ActionPanel>
            <Action title={on ? "Turn Off" : "Turn On"} icon={on ? Icon.XMarkCircle : Icon.CheckCircle} onAction={() => update(key, !on)} />
            <Action title="Refresh" icon={Icon.ArrowClockwise} shortcut={{ modifiers: ["cmd"], key: "r" }} onAction={reload} />
          </ActionPanel>
        }
      />
    );
  }
}

function EditText(props: { title: string; hint: string; value: string; onSave: (v: string) => void }) {
  const { pop } = useNavigation();
  return (
    <Form
      navigationTitle={props.title}
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Save"
            onSubmit={(v: { value: string }) => {
              props.onSave(v.value);
              pop();
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextArea id="value" title={props.title} info={props.hint} defaultValue={props.value} />
    </Form>
  );
}
