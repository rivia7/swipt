// Runs over USB before Swipt is installed. Turns off what blocks unattended use.
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const settings = "com.apple.Preferences";
const vpnApp = "com.jkcoxson.LocalDevVPN";
const vpnStore = "https://apps.apple.com/app/id6755608044";

// SwiftUI switches on iOS 27 ignore a short tap; a 200 ms press flips them.
const hold = ([x, y]) =>
  input.touch([
    [
      [x, y, 0],
      [x, y, 200],
    ],
  ]);

async function open(url) {
  await device.launchApplication(settings, { url, restart: true });
  await sleep(2200);
}

async function neverIsChecked(never) {
  const marks = (await accessibility.snapshot()).findAll({ label: "checkmark" });
  return marks.some((mark) => Math.abs(mark.point[1] - never.point[1]) < 14);
}

async function setAutoLockNever() {
  await open("prefs:root=DISPLAY&path=AUTOLOCK");
  const never = await accessibility.find(
    { label: /^(Never|永不)$/ },
    { timeoutMs: 4000, poll: true },
  );
  if (never === null) {
    throw new Error(
      "the Auto-Lock page has no Never option; is Low Power Mode on?",
    );
  }
  if (await neverIsChecked(never)) {
    return "already Never";
  }
  await input.tap(never.point);
  await sleep(1000);
  if (!(await neverIsChecked(never))) {
    throw new Error("Auto-Lock did not change to Never");
  }
  return "set to Never";
}

const standbySwitch = async () =>
  (await accessibility.snapshot())
    .findAll({ role: "switch" })
    .find((candidate) => !candidate.label);

// A locked phone charging in landscape enters StandBy, and device.unlock()
// cannot reach the passcode page from there.
async function turnOffStandBy() {
  await open("prefs:root=AMBIENT");
  const control = await standbySwitch();
  if (control === undefined) {
    throw new Error("the StandBy page shows no switch");
  }
  if (control.value !== "1") {
    return "already off";
  }
  await hold(control.point);
  await sleep(1200);
  if ((await standbySwitch())?.value !== "0") {
    throw new Error("StandBy did not turn off");
  }
  return "turned off";
}

const info = await device.info();
const result = { name: info.name, model: info.model, os: info.os };
if (await device.locked.get()) {
  throw new Error("the phone is locked; unlock it and run this again");
}
result.autoLock = await setAutoLockNever();
result.standBy = await turnOffStandBy();
const apps = await device.installedApplications();
result.vpnInstalled = apps.some((app) => app.bundleId === vpnApp);
result.swiptInstalled = apps.some((app) =>
  /^io\.nekohasekai\.swipt(\.|$)/.test(app.bundleId),
);
if (result.vpnInstalled) {
  await input.pressHome();
} else {
  await device.launchApplication("com.apple.AppStore", { url: vpnStore });
}
console.log("RESULT " + JSON.stringify(result));
