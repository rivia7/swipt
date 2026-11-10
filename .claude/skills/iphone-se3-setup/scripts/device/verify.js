// Runs over Wi-Fi against the Swipt app. Usage: verify.js [lock-test]
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
// Older nightly builds have device.screenshot() instead of screen.screenshot().
const screenshot = () =>
  typeof screen.screenshot === "function"
    ? screen.screenshot()
    : device.screenshot();

const result = {};
const info = await device.info();
result.device = [info.name, info.model, info.os];
result.locked = await device.locked.get();
result.front = await device.foregroundApplication.get();

let started = Date.now();
const shot = await screenshot();
result.screenshot = { size: [shot.width, shot.height], ms: Date.now() - started };

started = Date.now();
const elements = (await accessibility.snapshot()).findAll({ role: /./ }).length;
result.accessibility = { elements, ms: Date.now() - started };

if (args[0] === "lock-test") {
  const origin = result.front;
  await input.pressPower();
  await sleep(3000);
  if (!(await device.locked.get())) {
    throw new Error("the phone did not lock after the power button");
  }
  started = Date.now();
  await device.unlock();
  result.unlockMs = Date.now() - started;
  if (await device.locked.get()) {
    throw new Error("device.unlock() returned but the phone is still locked");
  }
  await device.launchApplication("com.apple.AppStore");
  await sleep(2000);
  result.openedApp = await device.foregroundApplication.get();
  if (result.openedApp !== "com.apple.AppStore") {
    throw new Error(`the App Store did not open: ${result.openedApp} is in front`);
  }
  if (origin !== "com.apple.springboard" && origin !== "com.apple.AppStore") {
    await device.launchApplication(origin);
  }
}
console.log("RESULT " + JSON.stringify(result));
