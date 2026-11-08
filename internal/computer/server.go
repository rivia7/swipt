//go:build darwin && cgo

package computer

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	E "github.com/sagernet/sing/common/exceptions"
	"github.com/swipt-automation/swipt/internal/api"
	"github.com/swipt-automation/swipt/internal/api/discovery"
	"github.com/swipt-automation/swipt/internal/automation"
	"github.com/swipt-automation/swipt/internal/device"
	"github.com/swipt-automation/swipt/internal/dnssd"
	"github.com/swipt-automation/swipt/internal/graphics"
	"github.com/swipt-automation/swipt/internal/log"
)

const (
	lockFile       = "server.lock"
	devicesFolder  = "Devices"
	swipletsFolder = "Swiplets"
	diskImages     = "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore"
	shutdownGrace  = 2 * time.Second
)

type Options struct {
	Device       string
	Passcode     string
	PasscodeType string
	DiskImage    string
	Version      string
	Logs         *log.Factory
	Output       io.Writer
}

func Run(ctx context.Context, options Options) error {
	passcodeKind, err := passcodeType(options.PasscodeType)
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	paired, err := chooseDevice(ctx, options.Device)
	if err != nil {
		return err
	}
	if !filepath.IsLocal(paired.UDID) {
		return E.New("the device reported an unusable UDID: ", paired.UDID)
	}
	directory := filepath.Join(home, "Library/Application Support/Swipt", devicesFolder, paired.UDID)
	caches := filepath.Join(home, "Library/Caches/Swipt", devicesFolder, paired.UDID)
	if err = os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	stored, err := loadSettings(directory)
	if err != nil {
		return err
	}
	host := LocalHostName() + ".local"
	url := func() string {
		return "http://" + net.JoinHostPort(host, strconv.Itoa(stored.Port))
	}
	held, err := acquire(filepath.Join(directory, lockFile), url())
	if err != nil {
		return err
	}
	defer held.Close()
	listener, err := net.Listen("tcp", ":"+strconv.Itoa(stored.Port))
	if errors.Is(err, syscall.EADDRINUSE) {
		stored.Port = randomPort()
		if err = stored.save(directory); err != nil {
			return err
		}
		listener, err = net.Listen("tcp", ":"+strconv.Itoa(stored.Port))
	}
	if err != nil {
		return E.Cause(err, "listen on port ", stored.Port)
	}
	defer listener.Close()

	diskImage := options.DiskImage
	if diskImage == "" {
		if _, err := os.Stat(diskImages); err == nil {
			diskImage = diskImages
		}
	}
	deviceLogger := options.Logs.NewLogger("device")
	connection := device.New(device.Options{
		Name:               paired.Name,
		Connect:            connect(paired.UDID, deviceLogger),
		Logger:             deviceLogger,
		Observer:           observer{},
		DiskImageDirectory: diskImage,
	})
	if options.Passcode != "" {
		if err = connection.UpdateSettings(device.Settings{AutoUnlockPasscode: options.Passcode, AutoUnlockPasscodeType: passcodeKind}); err != nil {
			return err
		}
	}
	if err = connection.Start(); err != nil {
		return err
	}
	defer connection.Close()
	swiplets := automation.New(automation.Options{
		Device:     connection.Phone(),
		Directory:  filepath.Join(directory, swipletsFolder),
		Caches:     filepath.Join(caches, swipletsFolder),
		Languages:  Languages(),
		LogFactory: options.Logs,
		Graphics:   graphics.New(graphics.Options{Connection: connection, Logger: options.Logs.NewLogger("graphics")}),
	})
	swiplets.Start()
	defer swiplets.Close()

	stop := make(chan struct{})
	var stopOnce sync.Once
	server := api.New(api.Options{
		Device: connection, Swiplets: swiplets, Logs: options.Logs, Logger: options.Logs.NewLogger("api"),
		AppVersion: options.Version, AppBuild: "macOS",
		Shutdown: func() { stopOnce.Do(func() { close(stop) }) },
	})
	advertisement, err := dnssd.Advertise(ctx, instanceName(paired), discovery.ServiceType, uint16(stored.Port), nil)
	if err != nil {
		return err
	}
	defer advertisement.Close()
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener, "", nil) }()
	fmt.Fprintln(options.Output, "Device:", paired.Name, "("+paired.UDID+")")
	fmt.Fprintln(options.Output, "Swipt API:", url())
	fmt.Fprintln(options.Output, "MCP:", url()+api.MCPPath)
	select {
	case <-ctx.Done():
	case <-stop:
	case err = <-served:
		if err != nil {
			return E.Cause(err, "serve the API")
		}
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	if err = server.Shutdown(shutdownCtx); err != nil {
		options.Logs.NewLogger("api").Debug("stopped: ", err)
	}
	return nil
}

func passcodeType(name string) (device.PasscodeType, error) {
	switch name {
	case "", "pin":
		return device.PasscodePIN, nil
	case "numeric":
		return device.PasscodeNumeric, nil
	case "alphanumeric":
		return device.PasscodeAlphanumeric, nil
	default:
		return 0, E.New("unknown passcode type ", name, "; it is pin, numeric or alphanumeric")
	}
}
