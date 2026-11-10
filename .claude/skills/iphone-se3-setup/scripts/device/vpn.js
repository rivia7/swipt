// Connects or disconnects LocalDevVPN by driving its screen. Usage: vpn.js on|off
const want = args[0];
if (want !== "on" && want !== "off") {
  throw new Error("usage: vpn.js on|off");
}
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const find = (label, timeoutMs) =>
  accessibility.find({ label }, { timeoutMs, poll: true });
const press = want === "on" ? /^Connect$/ : /^Disconnect$/;
const reached = want === "on" ? /^Disconnect$/ : /^Connect$/;
const state = want === "on" ? "connected" : "disconnected";

await device.launchApplication("com.jkcoxson.LocalDevVPN");
await sleep(1500);
const result = {};
if ((await find(reached, 1500)) !== null) {
  result.state = state;
  result.changed = false;
} else {
  const button = await find(press, 4000);
  if (button === null) {
    throw new Error("LocalDevVPN shows neither Connect nor Disconnect");
  }
  await input.tap(button.point);
  if ((await find(reached, 9000)) !== null) {
    result.state = state;
    result.changed = true;
  } else {
    // The first connection asks to add a VPN configuration, which takes the passcode.
    const sheet = await accessibility.find(
      { app: "com.apple.springboard", role: "sheet", label: /./ },
      { timeoutMs: 1000, poll: true },
    );
    result.state = "unknown";
    result.needsUser =
      sheet === null ? "the VPN did not change state" : sheet.label;
  }
}
console.log("RESULT " + JSON.stringify(result));
