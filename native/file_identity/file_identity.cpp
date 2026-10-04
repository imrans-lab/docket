#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#ifdef _WIN32
#include <windows.h>
#else
#include <cerrno>
#include <sys/stat.h>
#endif
using namespace godot;

// State is explicit: an unsuccessful query never proves two files different.
class DocketFileIdentity : public RefCounted {
    GDCLASS(DocketFileIdentity, RefCounted)
protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("inspect", "path"), &DocketFileIdentity::inspect);
        ClassDB::bind_method(D_METHOD("compare", "left", "right"), &DocketFileIdentity::compare);
    }
public:
    Dictionary inspect(const String &path) const {
        Dictionary result;
        result["state"] = "ERROR";
        result["token"] = "";
        if (path.is_empty()) return result;
        for (int i = 0; i < path.length(); ++i) if (path[i] == 0) return result;
#ifdef _WIN32
        const Char16String wide = path.utf16();
        HANDLE h = CreateFileW(reinterpret_cast<LPCWSTR>(wide.get_data()), FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS, nullptr);
        if (h == INVALID_HANDLE_VALUE) {
            DWORD error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) result["state"] = "ABSENT";
            return result;
        }
        FILE_ID_INFO id{};
        FILE_STANDARD_INFO info{};
        bool ok = GetFileInformationByHandleEx(h, FileIdInfo, &id, sizeof(id)) &&
                GetFileInformationByHandleEx(h, FileStandardInfo, &info, sizeof(info));
        bool closed = CloseHandle(h);
        if (!ok || !closed || info.Directory) return result;
        bool nonzero = false;
        for (unsigned char byte : id.FileId.Identifier) nonzero |= byte != 0;
        if (!nonzero) return result;
        PackedByteArray bytes;
        bytes.resize(sizeof(id.FileId.Identifier));
        for (unsigned i = 0; i < sizeof(id.FileId.Identifier); ++i) bytes.set(i, id.FileId.Identifier[i]);
        result["token"] = String::num_uint64(id.VolumeSerialNumber) + ":" + bytes.hex_encode();
#else
        struct stat info{};
        if (stat(path.utf8().get_data(), &info) != 0) {
            if (errno == ENOENT) result["state"] = "ABSENT";
            return result;
        }
        if (!S_ISREG(info.st_mode) || info.st_ino == 0) return result;
        result["token"] = String::num_uint64(info.st_dev) + ":" + String::num_uint64(info.st_ino);
#endif
        result["state"] = "PRESENT";
        return result;
    }
    Dictionary compare(const String &left, const String &right) const {
        Dictionary a = inspect(left), b = inspect(right), result;
        result["left"] = a;
        result["right"] = b;
        String sa = a["state"], sb = b["state"];
        result["state"] = sa == "ERROR" || sb == "ERROR" ? "ERROR" :
                sa == "ABSENT" || sb == "ABSENT" ? "ABSENT" :
                String(a["token"]) == String(b["token"]) ? "SAME" : "DIFFERENT";
        return result;
    }
};
static void initialize(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) ClassDB::register_class<DocketFileIdentity>();
}
static void terminate(ModuleInitializationLevel) {}
extern "C" GDExtensionBool GDE_EXPORT docket_file_identity_init(
        GDExtensionInterfaceGetProcAddress get_proc, GDExtensionClassLibraryPtr library,
        GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc, library, initialization);
    init.register_initializer(initialize);
    init.register_terminator(terminate);
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
