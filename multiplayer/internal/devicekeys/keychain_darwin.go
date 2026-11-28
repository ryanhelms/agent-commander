//go:build darwin && cgo

package devicekeys

/*
#cgo LDFLAGS: -framework Security -framework CoreFoundation
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
static CFMutableDictionaryRef lookup(const char *name) {
 CFMutableDictionaryRef q=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFStringRef account=CFStringCreateWithCString(NULL,name,kCFStringEncodingUTF8);
 CFDictionarySetValue(q,kSecClass,kSecClassGenericPassword);
 CFDictionarySetValue(q,kSecAttrService,CFSTR("Agent Commander Multiplayer"));
 CFDictionarySetValue(q,kSecAttrAccount,account); CFRelease(account); return q;
}
static OSStatus load_key(const char *name, void **bytes, long *size) {
 CFMutableDictionaryRef q=lookup(name);CFDataRef result=NULL;
 CFDictionarySetValue(q,kSecReturnData,kCFBooleanTrue);
 CFDictionarySetValue(q,kSecMatchLimit,kSecMatchLimitOne);
 OSStatus status=SecItemCopyMatching(q,(CFTypeRef *)&result);CFRelease(q);
 if(status==errSecSuccess){
   *size=CFDataGetLength(result);
   if(*size<=0||*size>(1<<20)){CFRelease(result);return errSecDecode;}
   *bytes=malloc(*size);
   if(!*bytes){CFRelease(result);return errSecAllocate;}
   memcpy(*bytes,CFDataGetBytePtr(result),*size);CFRelease(result);
 }
 return status;
}
static OSStatus save_key(const char *name,const void *bytes,long size) {
 CFMutableDictionaryRef q=lookup(name); CFDataRef value=CFDataCreate(NULL,bytes,size);
 CFMutableDictionaryRef data=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
 CFDictionarySetValue(data,kSecValueData,value);
 OSStatus status=SecItemUpdate(q,data);
 if(status==errSecItemNotFound){
  CFDictionarySetValue(q,kSecValueData,value);
  CFDictionarySetValue(q,kSecAttrAccessible,kSecAttrAccessibleWhenUnlockedThisDeviceOnly);
  status=SecItemAdd(q,NULL);
 }
 CFRelease(data); CFRelease(value); CFRelease(q);return status;
}
static OSStatus delete_key(const char *name) {
 CFMutableDictionaryRef q=lookup(name);OSStatus status=SecItemDelete(q);CFRelease(q);return status;
}
*/
import "C"
import (
	"errors"
	"fmt"
	"os"
	"strings"
	"unicode/utf8"
	"unsafe"
)

type keychain string

func (keychain) KeychainBacked() bool { return true }

func keychainError(operation string, status C.OSStatus) error {
	switch status {
	case C.errSecUserCanceled, C.errSecAuthFailed, C.errSecInteractionNotAllowed, C.errSecInteractionRequired, C.errSecNotAvailable:
		return fmt.Errorf("%s Keychain item (OSStatus %d): %w", operation, status, ErrKeychainAccess)
	default:
		return fmt.Errorf("%s Keychain item (OSStatus %d)", operation, status)
	}
}

func Keychain(account string) (Store, error) {
	if account == "" || len(account) > 512 || strings.ContainsRune(account, 0) || !utf8.ValidString(account) {
		return nil, errors.New("invalid Keychain account")
	}
	return keychain(account), nil
}
func (s keychain) Load() ([]byte, error) {
	n := C.CString(string(s))
	defer C.free(unsafe.Pointer(n))
	var ptr unsafe.Pointer
	var size C.long
	status := C.load_key(n, &ptr, &size)
	if status == C.errSecItemNotFound {
		return nil, os.ErrNotExist
	}
	if status != 0 {
		return nil, keychainError("read", status)
	}
	defer C.free(ptr)
	return C.GoBytes(ptr, C.int(size)), nil
}
func (s keychain) Save(data []byte) error {
	if len(data) == 0 || len(data) > maxRecord {
		return errors.New("invalid credential record size")
	}
	n := C.CString(string(s))
	defer C.free(unsafe.Pointer(n))
	status := C.save_key(n, unsafe.Pointer(&data[0]), C.long(len(data)))
	if status != 0 {
		return keychainError("write", status)
	}
	return nil
}
func (s keychain) Delete() error {
	n := C.CString(string(s))
	defer C.free(unsafe.Pointer(n))
	status := C.delete_key(n)
	if status != 0 && status != C.errSecItemNotFound {
		return fmt.Errorf("remove Keychain item (OSStatus %d)", status)
	}
	return nil
}
