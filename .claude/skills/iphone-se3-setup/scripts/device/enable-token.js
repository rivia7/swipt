// Runs over USB after install. Restarts Swipt, turns on API authentication and
// reports the API URL and the phone's Wi-Fi address.
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const find = (label, timeoutMs = 4000) =>
  accessibility.find({ label }, { timeoutMs, poll: true });
const hold = ([x, y]) =>
  input.touch([
    [
      [x, y, 0],
      [x, y, 200],
    ],
  ]);

// The scope for the whole screen is "screen" or "fullScreen", depending on the Swipt build.
async function wholeScreen() {
  for (const scope of ["screen", "fullScreen"]) {
    try {
      return await accessibility.snapshot({ scope });
    } catch (error) {
      if (!/scope/.test(error.message)) {
        throw error;
      }
    }
  }
  return accessibility.snapshot();
}

const toggles = async () =>
  (await accessibility.snapshot())
    .findAll({ role: "switch" })
    .filter((candidate) => !candidate.label);

async function turnOn(index, what) {
  const control = (await toggles())[index];
  if (control === undefined) {
    throw new Error(`Local Network shows no ${what} switch`);
  }
  if (control.value === "1") {
    return;
  }
  await hold(control.point);
  await sleep(1800);
  if ((await toggles())[index]?.value !== "1") {
    throw new Error(`the ${what} switch did not turn on`);
  }
}

const apps = await device.installedApplications();
const swipt = apps.find((app) =>
  /^io\.nekohasekai\.swipt(\.|$)/.test(app.bundleId),
);
if (swipt === undefined) {
  throw new Error("Swipt is not installed");
}
// A restart drops the --setup launch's invisible element, which blocks accessibility taps.
await device.launchApplication(swipt.bundleId, { restart: true });
await sleep(4000);

const tab = await find(/^Developer/, 6000);
if (tab === null) {
  const labels = (await accessibility.snapshot())
    .findAll({ role: /./ })
    .map((element) => element.label)
    .filter(Boolean)
    .slice(0, 6);
  throw new Error(
    `Swipt is not on its main screen, so setup is unfinished: ${labels.join(" | ")}`,
  );
}
await input.tap(tab.point);
await sleep(1500);
const row = await find(/^Local Network/);
if (row === null) {
  throw new Error("the Developer page has no Local Network row");
}
await input.tap(row.point);
await sleep(1500);

await turnOn(0, "publishing");
await turnOn(1, "authentication");

const show = await find(/^Show/, 3000);
if (show !== null) {
  await input.tap(show.point);
  await sleep(1200);
}
const urlElement = await find(/^http:\/\//, 3000);
const url = urlElement === null ? "" : urlElement.label;
const hide = await find(/^Hide/, 1500);
if (hide !== null) {
  await input.tap(hide.point);
  await sleep(600);
}

const host = await find(/^Host/, 3000);
if (host === null) {
  throw new Error("the Local Network page has no Host row");
}
await input.tap(host.point);
await sleep(1200);
const buttons = (await wholeScreen()).findAll({ role: "button" });
const addresses = buttons
  .map((button) => button.label ?? "")
  .filter((label) => /^\d+\.\d+\.\d+\.\d+$/.test(label));
// 169.254 is the USB link and 10.7 is the loopback VPN.
const wifi = addresses.find(
  (address) => !/^(169\.254|10\.7)\./.test(address),
);
const current = buttons.find((button) => /\.local$/.test(button.label ?? ""));
if (current !== undefined) {
  await input.tap(current.point);
}

console.log(
  "RESULT " +
    JSON.stringify({
      name: (await device.info()).name,
      url,
      port: /:(\d+)$/.exec(url)?.[1] ?? "",
      wifi: wifi ?? "",
      addresses,
    }),
);
