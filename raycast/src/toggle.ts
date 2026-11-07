import { showHUD, showToast, Toast } from "@raycast/api";
import { switchMode } from "./lib";

export default async function Command() {
  await showToast({ style: Toast.Style.Animated, title: "Switching…" });
  await showHUD(await switchMode("toggle"));
}
