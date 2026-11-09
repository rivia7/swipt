//go:build darwin && cgo

package computer

/*
#cgo LDFLAGS: -framework CoreFoundation -framework IOKit -framework SystemConfiguration
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <SystemConfiguration/SystemConfiguration.h>

static IOReturn swipt_prevent_sleep(void) {
	CFStringRef reason = CFSTR("Swipt is serving a device");
	IOPMAssertionID idle, system;
	IOReturn result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionLevelOn, reason, &idle);
	if (result != kIOReturnSuccess) {
		return result;
	}
	return IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionLevelOn, reason, &system);
}
*/
import "C"

import (
	"unsafe"

	E "github.com/sagernet/sing/common/exceptions"
)

// An idle Mac sleeps with phones attached and only an SSH session open, waking
// for seconds at a time, which stalls every tunnel (Apple M1, macOS 27.2 26B123).
// powerd ends a process's assertions when it exits, so they are never released here.
func preventSleep() error {
	if result := C.swipt_prevent_sleep(); result != 0 {
		return E.New("prevent the Mac from sleeping: IOReturn ", int32(result))
	}
	return nil
}

func Name() string {
	name := C.SCDynamicStoreCopyComputerName(0, nil)
	if name == 0 {
		return ""
	}
	defer C.CFRelease(C.CFTypeRef(name))
	return goString(name)
}

func LocalHostName() string {
	name := C.SCDynamicStoreCopyLocalHostName(0)
	if name == 0 {
		return ""
	}
	defer C.CFRelease(C.CFTypeRef(name))
	return goString(name)
}

func Languages() []string {
	list := C.CFLocaleCopyPreferredLanguages()
	if list == 0 {
		return nil
	}
	defer C.CFRelease(C.CFTypeRef(list))
	count := int(C.CFArrayGetCount(list))
	languages := make([]string, 0, count)
	for index := range count {
		languages = append(languages, goString(C.CFStringRef(C.CFArrayGetValueAtIndex(list, C.CFIndex(index)))))
	}
	return languages
}

func goString(value C.CFStringRef) string {
	length := C.CFStringGetMaximumSizeForEncoding(C.CFStringGetLength(value), C.kCFStringEncodingUTF8) + 1
	buffer := make([]byte, length)
	if C.CFStringGetCString(value, (*C.char)(unsafe.Pointer(&buffer[0])), length, C.kCFStringEncodingUTF8) == 0 {
		return ""
	}
	return C.GoString((*C.char)(unsafe.Pointer(&buffer[0])))
}
