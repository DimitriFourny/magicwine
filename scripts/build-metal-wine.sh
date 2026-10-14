#!/bin/bash
# Rebuild Wine 11's Metal, mouse-pointer, macOS WPAD and MSync modules/server.
# Requires Apple clang 21.0.0 (clang-2100.3.34.2), macOS SDK 26.5, make,
# flex, Perl, Python 3 and both x86_64/i686-w64-mingw32 GCC toolchains.
# The shipped corresponding-source archive supports the same command offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import gzip, hashlib, json, os, pathlib, shutil, subprocess, sys, tarfile, tempfile, zlib
root = pathlib.Path(sys.argv[1])
component = 'winemac-wine11.0-metal.7'
output = root / 'Sources/MagicWineCore/Resources'
local = root / '.local'
local.mkdir(exist_ok=True)
output.mkdir(parents=True, exist_ok=True)
work = pathlib.Path(tempfile.mkdtemp(prefix='metal-wine-build.', dir=local))
print('Build directory:', work, flush=True)
source_url = 'https://codeload.github.com/wine-mirror/wine/tar.gz/refs/tags/wine-11.0'
source_hash = 'f09e8153aa46a581d2b56a5b1363b04832070b9409d9244a68cf482b243ff14a'
stock_url = 'https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz'
stock_hash = 'b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388'
patch_hash = '64babc5970dcdc39e0e22120deaffe3de1dffabd6a4c9c5de4cda88b2ae7f59b'
link_hashes = {'libfreetype.6.dylib': 'df39a1b319ea882ca04bc2c800bfb7d225335890eefa48a173df856edf2d7946'}
freetype_url = 'https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz'
freetype_hash = '0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289'
original_native_win32u_hash = '5686c667977ab6d4ea932ea53a2a7b73e51c936988118707b85c7619db1dfb98'
original_user32_hashes = {'x86_64':'8ea5e7d18a3d1fc774f56a30c13c1abe0848a3a0af0c2d007e1b852e716a7496',
                          'i386':'6bc9d98d72f6f2e7a17d0c7f9dc62477f5d39ead0373f788ae60fb137b98e925'}
original_wow64win_hashes = {'x86_64':'9b87f84fb9320cb100f94b562fa15cbcbc9d84b29a0cf345324fb5f17f12cc39'}
original_winhttp_hashes = {'x86_64':'297679186e7cb8f82e559c02dbd4f40a6b2457e3ac32460f061d142f25f5a857',
                          'i386':'e1690fcfa7aff4d5add9645bb6b86c1a0a68debdcac75ea2ae55e7a43b7e32da'}
original_native_ntdll_hash = 'dfb9d4d4d6e7fd3dc537c1bacd69cb3a6bb46ae98311bb5358df3c4eab470c3f'
original_wineserver_hash = '6da7d389c5a35687e580c4988e03f830a73786cf13aba6761e4791ab74aeea2e'
original_hash = '7687c4095ea6dba1761052ac19d46db3409a36f2bc827b79c6e32bf779df59f4'
original_pe_hashes = {'x86_64':'9c52f24507b692ef0fcc0dc5439b8bee63f869f04ef38494bf52e52ddfbfecf0',
                      'i386':'200a8cd50084d1bd70511681082fbe152a585a8638e84a5aafe8148a8248cda5'}
original_ntdll_hashes = {'x86_64':'d63d10c77a55105d68bf1935ff10137d2ab5e8a4c6ae329aee599f17524b2755',
                        'i386':'bac6f2d9434860d09a696dcdcd5f85631e19fd4f9409b3a39828841b7a40c089'}
epoch = 1768262400
sdk = pathlib.Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
if not sdk.is_dir(): raise SystemExit('macOS SDK 26.5 is required; no SDK/toolchain is installed by this script')
for tool in ('clang', 'make', 'bison', 'flex', 'perl', 'patch', 'nm', 'otool', 'file', 'install_name_tool', 'x86_64-w64-mingw32-gcc', 'i686-w64-mingw32-gcc'):
    if not shutil.which(tool): raise SystemExit('Missing prerequisite: ' + tool)
clang_version = subprocess.check_output(['clang', '--version'], text=True)
if 'clang-2100.3.34.2' not in clang_version: raise SystemExit('Pinned Apple clang-2100.3.34.2 is required')
env = os.environ.copy()
for key in ('CC','CXX','CFLAGS','CXXFLAGS','CPPFLAGS','LDFLAGS','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','WINEPREFIX','WINEARCH','SDKROOT','MACOSX_DEPLOYMENT_TARGET',
            'FREETYPE_CFLAGS','FREETYPE_LIBS','FREETYPE_CONFIG','FREETYPE2_CONFIG','PKG_CONFIG','PKG_CONFIG_PATH','PKG_CONFIG_LIBDIR','CONFIG_SITE'):
    env.pop(key, None)
env.update(LC_ALL='C', TZ='UTC', COPYFILE_DISABLE='1', SOURCE_DATE_EPOCH=str(epoch))
def sha(path):
    with open(path, 'rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def verify(path, digest):
    if path.is_symlink() or not path.is_file() or sha(path) != digest:
        raise SystemExit('SHA-256/file-type mismatch: ' + str(path))
def fetch(url, path, digest):
    if not path.exists():
        temporary = work / 'download'
        subprocess.run(['curl','--fail','--location','--proto','=https','--tlsv1.2',url,'-o',str(temporary)],check=True)
        verify(temporary,digest)
        temporary.replace(path)
    verify(path,digest)
    return path
commands = []
def run(args, cwd):
    commands.append([str(arg) for arg in args])
    with (work / 'build.log').open('ab') as log:
        result = subprocess.run(args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode:
        print((work / 'build.log').read_text()[-16000:])
        raise SystemExit('Build failed; full log: ' + str(work / 'build.log'))
patch = root / 'patches/wine-metal-driver.patch'
verify(patch,patch_hash)
pointer_patch = root / 'patches/wine-mouse-pointer.patch'
pointer_patch_hash = '309c602a281e65c62f71d9e69b19bb270c0e2fa982af4312b2a4a4ebe65536d9'
verify(pointer_patch,pointer_patch_hash)
wpad_patch = root / 'patches/wine-wpad-macos.patch'
wpad_patch_hash = '4742d98e57e4c61c0fe42dc8f5a3db52efa265c0c14f1b917b7f325ccd1e7a20'
verify(wpad_patch,wpad_patch_hash)
remote_patch = root / 'patches/wine-remote-metal.patch'
remote_patch_hash = '373a97240b94902a8fa89b1afe89d138fd87c4d09a4d378f94a1d6faa9fb7809'
verify(remote_patch,remote_patch_hash)
msync_patch = root / 'patches/wine-msync.patch'
msync_patch_hash = '7e9b8ab7f41b6b2f96705d5deb5a5b97ae78e28e76e5416ed1196a0a0719898d'
verify(msync_patch,msync_patch_hash)
msync_commit = 'b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc'
msync_source_url = 'https://raw.githubusercontent.com/rnowak/wine-crossover-sources/' + msync_commit + '/wine/'
msync_inputs = {
    'COPYING.LIB':'e237fa56668030e928551ddd60f05df5fe957f75eab874bbd017e085ed722e7c',
    'dlls/ntdll/Makefile.in':'70b869abb93b8e402b28543f30aca31f23eceebefd2b602c2aab695fe3b72b99',
    'dlls/ntdll/unix/loader.c':'451eb34296572d19e072b7399f5e4d6b053a0e809ccb0dedfe18da7c523703b2',
    'dlls/ntdll/unix/msync.c':'30dd83ed51240bfaf206bd16a6b765c6dfe748fba10265306a122c3281588cda',
    'dlls/ntdll/unix/msync.h':'82b8d07b239ef764369d3288e5dde899174f6142b8781c53a7200badf59aa642',
    'dlls/ntdll/unix/sync.c':'005810749de981c2dcd056d72696b14edd60c9b7549a2bf80b0e07ee1d211374',
    'server/Makefile.in':'28dbdf0bc9d72590ab82a48ffb04fedace86f9a1b1f3b75c0b15b872968491c4',
    'server/main.c':'e0ebac36730e92ee0f6ecae4c69a04bb56434739149cd13253f37db9d995bbd2',
    'server/inproc_sync.c':'79009f53d087430a5b41efbc9e5b645f5ec55cf1438bebd260a7ed756f14899f',
    'server/msync.c':'75b0e6780381c9ecbb8efd0e34f6e3d127c7de9c09937e6009ba3b8332d7b8a1',
    'server/msync.h':'9ba0838d6c801a908f846bd0e324ac65db8d0fc628cebc2b8fa204534c8b0d6d',
    'server/protocol.def':'efcfc4fef3a0e2c02ada7eeae79a32cc947b1537d4f218caad220b2a6bac3c2b',
    'server/thread.c':'ad946fe2e7d12245d11005b07ceaa806339a53729c4afb391d93bf8fa6f5d971'}
inputs = work / 'source-inputs'
inputs.mkdir()
offline = root / 'source-inputs'
# Retain the exact public LGPL implementation and integration references for
# attribution/review; the final backport itself is fully contained in the patch.
for name,digest in msync_inputs.items():
    cached = local / 'msync-upstream' / msync_commit / name
    cached.parent.mkdir(parents=True,exist_ok=True)
    original = offline / 'msync-upstream' / name if offline.is_dir() else fetch(
        msync_source_url + name,cached,digest)
    verify(original,digest)
    target = inputs / 'msync-upstream' / name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(original,target)
# Use architecture-independent headers from a pinned public source release, not
# whichever Homebrew architecture/version happens to be installed on the host.
freetype_archive = offline / 'freetype-2.13.3.tar.xz' if offline.is_dir() else fetch(
    freetype_url,local / 'freetype-2.13.3.tar.xz',freetype_hash)
verify(freetype_archive,freetype_hash)
shutil.copyfile(freetype_archive,inputs / freetype_archive.name)
with tarfile.open(freetype_archive) as tar: tar.extractall(work, filter='data')
freetype = work / 'freetype-2.13.3'
# Apple's Bison 2.3 cannot configure Wine. Build the pinned public tool locally;
# it never replaces or installs any developer tool outside this build directory.
bison_hash = '06c9e13bdf7eb24d4ceb6b59205a4f67c2c7e7213119644430fe82fbd14a0abb'
bison_archive = offline / 'bison-3.8.2.tar.gz' if offline.is_dir() else fetch(
    'https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.gz', local / 'bison-3.8.2.tar.gz', bison_hash)
verify(bison_archive,bison_hash)
shutil.copyfile(bison_archive,inputs / bison_archive.name)
with tarfile.open(bison_archive) as tar: tar.extractall(work, filter='data')
bison = work / 'bison-3.8.2'
run([str(bison / 'configure'),'--disable-nls','--prefix=' + str(work / 'tools')],bison)
run(['make','-j4'],bison)
run(['make','install'],bison)
env['PATH'] = str(work / 'tools/bin') + os.pathsep + env['PATH']
source = inputs / 'wine-11.0.tar.gz'
if offline.is_dir():
    verify(offline / source.name,source_hash)
    shutil.copyfile(offline / source.name,source)
    for name, digest in link_hashes.items():
        verify(offline / name,digest)
        shutil.copyfile(offline / name,inputs / name)
else:
    archive = fetch(source_url,local / 'wine-11.0-wow64cpu-source.tar.gz',source_hash)
    shutil.copyfile(archive,source)
    stock = fetch(stock_url,local / 'wine-stable-11.0_1-osx64.tar.xz',stock_hash)
    with tarfile.open(stock) as tar:
        member = tar.getmember('Wine Stable.app/Contents/Resources/wine/bin/wineserver')
        if not member.isfile() or not member.mode & 0o111 or hashlib.sha256(tar.extractfile(member).read()).hexdigest() != original_wineserver_hash:
            raise SystemExit('Stock wineserver SHA-256/file-type/mode mismatch')
        for name,digest in link_hashes.items():
            member = tar.getmember('Wine Stable.app/Contents/Resources/wine/lib/' + name)
            if not member.isfile(): raise SystemExit('Link input is not a regular file')
            (inputs / name).write_bytes(tar.extractfile(member).read())
            verify(inputs / name,digest)
        stock_modules = {'wine/x86_64-unix/win32u.so':original_native_win32u_hash,
                         **{'wine/' + arch + '-windows/user32.dll':digest for arch,digest in original_user32_hashes.items()},
                         **{'wine/' + arch + '-windows/wow64win.dll':digest for arch,digest in original_wow64win_hashes.items()},
                         **{'wine/' + arch + '-windows/winhttp.dll':digest for arch,digest in original_winhttp_hashes.items()}}
        if 'Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/winhttp.so' in tar.getnames():
            raise SystemExit('Stock runtime unexpectedly contains native winhttp.so')
        for name,digest in stock_modules.items():
            member = tar.getmember('Wine Stable.app/Contents/Resources/wine/lib/' + name)
            if not member.isfile() or hashlib.sha256(tar.extractfile(member).read()).hexdigest() != digest:
                raise SystemExit('Stock module SHA-256/file-type mismatch: ' + name)
with tarfile.open(source) as tar: tar.extractall(work, filter='data')
src = work / 'wine-wine-11.0'
run(['patch','--batch','--forward','--fuzz=0','-p1','-i',str(patch)],src)
run(['patch','--batch','--forward','--fuzz=0','-p1','-i',str(pointer_patch)],src)
run(['patch','--batch','--forward','--fuzz=0','-p1','-i',str(wpad_patch)],src)
run(['patch','--batch','--forward','--fuzz=0','-p1','-i',str(remote_patch)],src)
run(['patch','--batch','--forward','--fuzz=0','-p1','-i',str(msync_patch)],src)
# Regenerate the client and server from the same protocol. Generated results
# are also present in the patch so the offline source contains the exact ABI.
run(['perl','tools/make_requests'],src)
if '#define SERVER_PROTOCOL_VERSION 932' not in (src / 'include/wine/server_protocol.h').read_text():
    raise SystemExit('Unexpected MSync client/server protocol version')
build = work / 'build'
build.mkdir()
# FreeType is dlopened, not linked into win32u. Keep configure's link checks
# architecture-correct, then resolve dlopen relative to lib/wine/x86_64-unix
# rather than relying on the launching shell's dynamic-library search path.
font_link = work / 'font-link'
font_link.mkdir()
shutil.copyfile(inputs / 'libfreetype.6.dylib',font_link / 'libfreetype.6.dylib')
(font_link / 'libfreetype.dylib').symlink_to('libfreetype.6.dylib')
flags = '-O2 -g0 -arch x86_64 -isysroot ' + str(sdk) + ' -mmacosx-version-min=10.15 -ffile-prefix-map=' + str(work) + '=.'
run([str(src / 'configure'),'--build=x86_64-apple-darwin','--host=x86_64-apple-darwin',
     '--enable-archs=i386,x86_64','--disable-tests','--without-x','--with-freetype','--without-fontconfig','--with-vulkan',
     'PKG_CONFIG=false','FREETYPE_CFLAGS=-I' + str(freetype / 'include'),
     'FREETYPE_LIBS=-L' + str(font_link) + ' -lfreetype',
     'ac_cv_lib_soname_freetype=@loader_path/../../libfreetype.6.dylib',
     'ac_cv_lib_soname_vulkan=',
     'ac_cv_lib_soname_MoltenVK=@loader_path/../../libMoltenVK.dylib',
     'CC=clang -arch x86_64', 'CFLAGS=' + flags,
     'x86_64_CFLAGS=-O2 -g0 -ffile-prefix-map=' + str(work) + '=.',
     'i386_CFLAGS=-O2 -g0 -ffile-prefix-map=' + str(work) + '=.',
     'LDFLAGS=-arch x86_64 -isysroot ' + str(sdk) + ' -mmacosx-version-min=10.15'],build)
config_header = (build / 'include/config.h').read_text()
if '#define HAVE_FT2BUILD_H 1' not in config_header or '#define SONAME_LIBFREETYPE "@loader_path/../../libfreetype.6.dylib"' not in config_header:
    raise SystemExit('Native win32u requires FreeType headers and the stock runtime-local soname')
if '#define SONAME_LIBVULKAN "@loader_path/../../libMoltenVK.dylib"' not in config_header:
    raise SystemExit('Native win32u must preserve Vulkan through the stock runtime-local MoltenVK loader')
# Build the native driver with the matching rebuilt win32u/ntdll modules.
units = sorted(p.stem for p in (src / 'dlls/winemac.drv').iterdir()
               if p.suffix == '.m' or (p.suffix == '.c' and '#pragma makedep unix' in p.read_text()))
objects = ['dlls/winemac.drv/' + unit + '.o' for unit in units]
native_ntdll = build / 'dlls/ntdll/ntdll.so'
native_win32u = build / 'dlls/win32u/win32u.so'
native_winhttp = build / 'dlls/winhttp/winhttp.so'
wineserver = build / 'server/wineserver'
run(['make','-j4',*objects,'dlls/ntdll/ntdll.so','dlls/win32u/win32u.so','dlls/winhttp/winhttp.so','server/wineserver'],build)
frameworks = ['AppKit','Carbon','CoreVideo','Foundation','IOKit','Metal','OpenGL','QuartzCore','Security']
link = ['clang','-arch','x86_64','-isysroot',str(sdk),'-mmacosx-version-min=10.15','-dynamiclib',
        '-Wl,-headerpad_max_install_names','-Wl,-install_name,winemac.so','-o','winemac.so',*objects,
        str(native_ntdll),str(native_win32u)]
for framework in frameworks: link += ['-framework',framework]
run(link,build)
driver = build / 'winemac.so'
pe_drivers = {arch:build / ('dlls/winemac.drv/' + arch + '-windows/winemac.drv') for arch in ('x86_64','i386')}
pe_ntdll = {arch:build / ('dlls/ntdll/' + arch + '-windows/ntdll.dll') for arch in ('x86_64','i386')}
pe_user32 = {arch:build / ('dlls/user32/' + arch + '-windows/user32.dll') for arch in ('x86_64','i386')}
pe_wow64win = {'x86_64':build / 'dlls/wow64win/x86_64-windows/wow64win.dll'}
pe_winhttp = {arch:build / ('dlls/winhttp/' + arch + '-windows/winhttp.dll') for arch in ('x86_64','i386')}
run(['make','-j4',*[str(path.relative_to(build)) for path in
                  [*pe_drivers.values(), *pe_ntdll.values(), *pe_user32.values(), *pe_wow64win.values(), *pe_winhttp.values()]]],build)
exports = subprocess.check_output(['nm','-gU',str(driver)],text=True)
required = ['macdrv_functions','magicwine_metal_bridge_v1','magicwine_metal_remote_v1',
            'magicwine_metal_remote_copy_layer',
            '__wine_unix_call_funcs','__wine_unix_call_wow64_funcs']
for name in required:
    if not any(line.endswith(' _'+name) for line in exports.splitlines()): raise SystemExit('Missing driver export: '+name)
linkage = subprocess.check_output(['otool','-L',str(driver)],text=True)
if '@rpath/ntdll.so' not in linkage or '@rpath/win32u.so' not in linkage: raise SystemExit('Wrong Wine linkage')
architecture = subprocess.check_output(['file',str(driver)],text=True)
if 'Mach-O 64-bit dynamically linked shared library x86_64' not in architecture: raise SystemExit('Wrong native architecture')
ntdll_exports = subprocess.check_output(['nm','-gU',str(native_ntdll)],text=True)
for name in ('__wine_main','magicwine_metal_ntdll_v1','NtCreateThreadEx','NtClose','NtCreateSemaphore',
             'NtReleaseSemaphore','NtCreateEvent','NtSetEvent','NtResetEvent','NtClearEvent','NtPulseEvent'):
    if not any(line.endswith(' _'+name) for line in ntdll_exports.splitlines()):
        raise SystemExit('Missing native ntdll export: '+name)
win32u_linkage = subprocess.check_output(['otool','-L',str(native_win32u)],text=True)
if '@rpath/ntdll.so' not in win32u_linkage: raise SystemExit('Wrong native win32u linkage')
win32u_architecture = subprocess.check_output(['file',str(native_win32u)],text=True)
if 'Mach-O 64-bit dynamically linked shared library x86_64' not in win32u_architecture:
    raise SystemExit('Wrong native win32u architecture')
winhttp_linkage = subprocess.check_output(['otool','-L',str(native_winhttp)],text=True)
for dependency in ('@rpath/ntdll.so','/System/Library/Frameworks/SystemConfiguration.framework/',
                   '/System/Library/Frameworks/CoreFoundation.framework/'):
    if dependency not in winhttp_linkage: raise SystemExit('Missing native winhttp dependency: ' + dependency)
winhttp_architecture = subprocess.check_output(['file',str(native_winhttp)],text=True)
if 'Mach-O 64-bit dynamically linked shared library x86_64' not in winhttp_architecture:
    raise SystemExit('Wrong native winhttp architecture')
winhttp_exports = subprocess.check_output(['nm','-gU',str(native_winhttp)],text=True)
for name in ('__wine_unix_call_funcs','__wine_unix_call_wow64_funcs'):
    if not any(line.endswith(' _'+name) for line in winhttp_exports.splitlines()):
        raise SystemExit('Missing native winhttp export: ' + name)
wineserver_linkage = subprocess.check_output(['otool','-L',str(wineserver)],text=True)
wineserver_architecture = subprocess.check_output(['file',str(wineserver)],text=True)
if 'Mach-O 64-bit executable x86_64' not in wineserver_architecture:
    raise SystemExit('Wrong wineserver architecture')
if not os.access(wineserver,os.X_OK): raise SystemExit('Rebuilt wineserver is not executable')
for dependency in wineserver_linkage.splitlines()[1:]:
    name = dependency.strip().split(' (',1)[0]
    if not name.startswith(('/usr/lib/','/System/Library/')):
        raise SystemExit('Non-system wineserver dependency: ' + name)
for module,module_linkage in ((driver,linkage),(native_win32u,win32u_linkage),(native_winhttp,winhttp_linkage)):
    for dependency in module_linkage.splitlines()[1:]:
        name = dependency.strip().split(' (',1)[0]
        if not name.startswith(('@rpath/','/usr/lib/','/System/Library/')) and name != 'winemac.so':
            raise SystemExit('Non-runtime-local native dependency in ' + module.name + ': ' + name)
payload = work / (component + '-source')
payload.mkdir()
shutil.copytree(inputs,payload / 'source-inputs')
for name in ('scripts/build-metal-wine.sh','patches/wine-metal-driver.patch','patches/wine-mouse-pointer.patch',
             'patches/wine-wpad-macos.patch','patches/wine-remote-metal.patch','patches/wine-msync.patch',
             'Tests/WineMSyncTests.c','scripts/test-msync.sh',
             'Tests/WineProxyTests.c','Tests/WineProxyPolicyTests.c','scripts/test-wine-proxy.sh',
             'Tests/WineRemotePresentationTests.cpp','scripts/test-remote-presentation.sh'):
    target = payload / name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(root / name,target)
shutil.copytree(src / 'dlls/winemac.drv',payload / 'patched-driver')
shutil.copytree(src / 'dlls/ntdll',payload / 'patched-ntdll')
shutil.copytree(src / 'server',payload / 'patched-server')
(payload / 'patched-include/wine').mkdir(parents=True)
shutil.copyfile(src / 'include/wine/server_protocol.h',payload / 'patched-include/wine/server_protocol.h')
for module in ('win32u','user32','wow64win','winhttp'):
    shutil.copytree(src / 'dlls' / module,payload / ('patched-' + module))
license_text = ('MagicWine Metal, mouse-pointer, macOS WPAD and MSync Wine support: public Wine 11 native and PE\n'
                'winemac/ntdll/win32u/user32/wow64win/winhttp modules and matching wineserver with the public Unix-call entry\n'
                'point, native pthread TLS, D3DMetal Nt ABI, mouse-pointer input support,\n'
                'remote root/child Metal layer hosting, and macOS proxy autodiscovery policy.\n'
                'The MagicWine D3DMetal/DXMT client-surface bridge is LGPL-2.1-or-later.\n'
                'ABI reference: Whisky-App/wine a92f7f06c4cff7291578e58eb95284b00e322799,\n'
                'dlls/winemac.drv/macdrv_main.c and macdrv.h (LGPL-2.1-or-later).\n'
                'Remote Metal transport: Wine commit 1a63b0d7c431f1ebbaba9afd2daa312690eb8020,\n'
                'Marc-Aurel Zent / CodeWeavers (LGPL-2.1-or-later), adapted to Wine 11 and child HWNDs.\n'
                'Native ABI source references: CodeWeavers CrossOver 26.1 public source mirror,\n'
                'rnowak/wine-crossover-sources b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc;\n'
                'Alien4042x/WineForge a342f4aeb23d719339f444b9e94e06ecf0ff1a14 (LGPL-2.1-or-later).\n'
                'MSync: Marc-Aurel Zent and Zebediah Figura (LGPL-2.1-or-later),\n'
                'https://github.com/marzent/wine-msync; Wine 11 inproc-sync integration from\n'
                'the pinned public CrossOver source above. Original files and COPYING.LIB\n'
                'are preserved under source-inputs/msync-upstream; the attributed backport\n'
                'and generated protocol are included. WINEMSYNC=1 uses Mach messages,\n'
                'shared memory and Darwin ulocks; WINEMSYNC=0 uses normal server sync.\n'
                'No proprietary CrossOver or Apple binaries are included.\n'
                'Original Wine file copyright notices are retained in the corresponding source.\n'
                'Rebuild offline: extract the adjacent -source.tar.gz and run bash scripts/build-metal-wine.sh.\n'
                'The source bundle includes the complete original Wine 11 source archive,\n'
                'patches, recipe, and public pinned native link inputs. FreeType 2.13.3 source\n'
                'and its FTL/GPLv2 licenses are included in source-inputs/freetype-2.13.3.tar.xz;\n'
                'only its headers and a stock configure-link input are used. The rebuilt\n'
                'win32u loads the existing runtime libfreetype.6.dylib without absolute paths.\n\n' +
                (src / 'COPYING.LIB').read_text())
(payload / 'LICENSE-WINE-METAL.txt').write_text(license_text)
# Package opaque bytes so Swift release resource processing cannot rewrite the
# Mach-O image (for example by stripping symbols) after its hash is pinned.
compressed_driver = work / (component + '.so.deflate')
# Foundation's NSData .zlib algorithm uses the RFC 1951 raw DEFLATE stream,
# without an RFC 1950 zlib header/checksum. Integrity comes from compiled pins.
compressor = zlib.compressobj(wbits=-15)
compressed_driver.write_bytes(compressor.compress(driver.read_bytes()) + compressor.flush())
compressed_native_ntdll = work / (component + '-ntdll.so.deflate')
compressor = zlib.compressobj(wbits=-15)
compressed_native_ntdll.write_bytes(compressor.compress(native_ntdll.read_bytes()) + compressor.flush())
compressed_wineserver = work / (component + '-wineserver.deflate')
compressor = zlib.compressobj(wbits=-15)
compressed_wineserver.write_bytes(compressor.compress(wineserver.read_bytes()) + compressor.flush())
compressed_pe = {}
for arch, path in pe_drivers.items():
    compressed_pe[arch] = work / (component + '-' + arch + '.drv.deflate')
    compressor = zlib.compressobj(wbits=-15)
    compressed_pe[arch].write_bytes(compressor.compress(path.read_bytes()) + compressor.flush())
compressed_ntdll = {}
for arch, path in pe_ntdll.items():
    compressed_ntdll[arch] = work / (component + '-' + arch + '.ntdll.deflate')
    compressor = zlib.compressobj(wbits=-15)
    compressed_ntdll[arch].write_bytes(compressor.compress(path.read_bytes()) + compressor.flush())
compressed_native_win32u = work / (component + '-win32u.so.deflate')
compressor = zlib.compressobj(wbits=-15)
compressed_native_win32u.write_bytes(compressor.compress(native_win32u.read_bytes()) + compressor.flush())
compressed_user32 = {}
for arch,path in pe_user32.items():
    compressed_user32[arch] = work / (component + '-' + arch + '.user32.deflate')
    compressor = zlib.compressobj(wbits=-15)
    compressed_user32[arch].write_bytes(compressor.compress(path.read_bytes()) + compressor.flush())
compressed_wow64win = {}
for arch,path in pe_wow64win.items():
    compressed_wow64win[arch] = work / (component + '-' + arch + '.wow64win.deflate')
    compressor = zlib.compressobj(wbits=-15)
    compressed_wow64win[arch].write_bytes(compressor.compress(path.read_bytes()) + compressor.flush())
compressed_native_winhttp = work / (component + '-winhttp.so.deflate')
compressor = zlib.compressobj(wbits=-15)
compressed_native_winhttp.write_bytes(compressor.compress(native_winhttp.read_bytes()) + compressor.flush())
compressed_winhttp = {}
for arch,path in pe_winhttp.items():
    compressed_winhttp[arch] = work / (component + '-' + arch + '.winhttp.deflate')
    compressor = zlib.compressobj(wbits=-15)
    compressed_winhttp[arch].write_bytes(compressor.compress(path.read_bytes()) + compressor.flush())
metadata = {'component':component,'source':{'url':source_url,'sha256':source_hash},
            'stock':{'url':stock_url,'sha256':stock_hash,'original_driver_sha256':original_hash,
                     'original_pe_sha256':original_pe_hashes,'original_ntdll_sha256':original_ntdll_hashes,
                     'original_native_ntdll_sha256':original_native_ntdll_hash,
                     'original_wineserver_sha256':original_wineserver_hash,
                     'original_native_win32u_sha256':original_native_win32u_hash,
                     'original_user32_sha256':original_user32_hashes,
                     'original_wow64win_sha256':original_wow64win_hashes,
                     'original_winhttp_sha256':original_winhttp_hashes},
            'patch_sha256':patch_hash,'mouse_pointer_patch_sha256':pointer_patch_hash,
            'wpad_macos_patch_sha256':wpad_patch_hash,
            'remote_metal_patch_sha256':remote_patch_hash,
            'msync_patch_sha256':msync_patch_hash,
            'msync':{'url':msync_source_url,'commit':msync_commit,'inputs_sha256':msync_inputs,
                     'design_url':'https://github.com/marzent/wine-msync',
                     'license':'LGPL-2.1-or-later','protocol_version':932,
                     'shared_slot_bytes':32,'reference_count_bits':32,'object_index_bits':28,
                     'environment':'WINEMSYNC=1/0','startup_marker':'msync: up and running.'},
            'link_inputs_sha256':link_hashes,
            'freetype':{'url':freetype_url,'sha256':freetype_hash,'version':'2.13.3',
                        'runtime_soname':'@loader_path/../../libfreetype.6.dylib',
                        'link_input_stock_member':'Wine Stable.app/Contents/Resources/wine/lib/libfreetype.6.dylib'},
            'vulkan_runtime_soname':'@loader_path/../../libMoltenVK.dylib',
            'metal_contract':{'url':'https://github.com/Whisky-App/wine/blob/a92f7f06c4cff7291578e58eb95284b00e322799/dlls/winemac.drv/macdrv_main.c',
                              'table_slots':24,'window_data_bytes':120,'client_view_offset':24},
            'dxmt_contract':{'url':'https://github.com/3Shain/dxmt/blob/v0.80/src/winemetal/unix/winemetal_unix.c',
                             'consumed_table_prefix_slots':10},
            'pe_sha256':{arch:sha(path) for arch,path in pe_drivers.items()},
            'compressed_pe_sha256':{arch:sha(path) for arch,path in compressed_pe.items()},
            'ntdll_sha256':{arch:sha(path) for arch,path in pe_ntdll.items()},
            'compressed_ntdll_sha256':{arch:sha(path) for arch,path in compressed_ntdll.items()},
            'user32_sha256':{arch:sha(path) for arch,path in pe_user32.items()},
            'compressed_user32_sha256':{arch:sha(path) for arch,path in compressed_user32.items()},
            'wow64win_sha256':{arch:sha(path) for arch,path in pe_wow64win.items()},
            'compressed_wow64win_sha256':{arch:sha(path) for arch,path in compressed_wow64win.items()},
            'native_win32u_sha256':sha(native_win32u),
            'compressed_native_win32u_sha256':sha(compressed_native_win32u),
            'native_win32u_linkage':win32u_linkage.replace(str(native_win32u),'win32u.so'),
            'native_winhttp_sha256':sha(native_winhttp),
            'compressed_native_winhttp_sha256':sha(compressed_native_winhttp),
            'native_winhttp_linkage':winhttp_linkage.replace(str(native_winhttp),'winhttp.so'),
            'winhttp_sha256':{arch:sha(path) for arch,path in pe_winhttp.items()},
            'compressed_winhttp_sha256':{arch:sha(path) for arch,path in compressed_winhttp.items()},
            'compiler':clang_version.strip(),'sdk':'26.5','deployment_target':'10.15',
            'source_date_epoch':epoch,'driver_sha256':sha(driver),
            'native_ntdll_sha256':sha(native_ntdll),
            'compressed_native_ntdll_sha256':sha(compressed_native_ntdll),
            'wineserver_sha256':sha(wineserver),
            'compressed_wineserver_sha256':sha(compressed_wineserver),
            'wineserver_linkage':wineserver_linkage.replace(str(wineserver),'wineserver'),
            'wineserver_mode':'0755','wineserver_install_path':'bin/wineserver',
            'native_ntdll_exports':ntdll_exports.replace(str(native_ntdll),'ntdll.so'),
            'compressed_driver_sha256':sha(compressed_driver),
            'commands':[[arg.replace(str(work),'.').replace(str(root),'${ROOT}') for arg in cmd] for cmd in commands],
            'exports':exports.replace(str(driver),'winemac.so'),
            'linkage':linkage.replace(str(driver),'winemac.so'),
            'inputs_sha256':{str(p.relative_to(payload)):sha(p) for p in sorted(payload.rglob('*')) if p.is_file()}}
provenance = json.dumps(metadata,indent=2,sort_keys=True)+'\n'
(payload / 'provenance.json').write_text(provenance)
archive = work / (component + '-source.tar.gz')
with archive.open('wb') as raw, gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=epoch) as compressed:
    with tarfile.open(fileobj=compressed,mode='w',format=tarfile.PAX_FORMAT) as tar:
        for path in sorted(payload.rglob('*')):
            entry = tar.gettarinfo(str(path),arcname=str(path.relative_to(payload)))
            entry.uid=entry.gid=0
            entry.uname=entry.gname=''
            entry.mtime=epoch
            entry.mode=0o755 if path.is_dir() else 0o644
            if path.is_file():
                with path.open('rb') as f: tar.addfile(entry,f)
            else: tar.addfile(entry)
# Publish binary last; interruption never publishes a driver without its source.
for path,name in [(archive,archive.name),(payload / 'LICENSE-WINE-METAL.txt','LICENSE-WINE-METAL.txt'),
                  (payload / 'provenance.json',component+'-provenance.json'),(compressed_driver,compressed_driver.name),
                  (compressed_native_ntdll,compressed_native_ntdll.name),
                  (compressed_wineserver,compressed_wineserver.name),
                  (compressed_native_win32u,compressed_native_win32u.name),
                  (compressed_native_winhttp,compressed_native_winhttp.name),
                  *[(path,path.name) for path in [*compressed_pe.values(), *compressed_ntdll.values(),
                                                  *compressed_user32.values(), *compressed_wow64win.values(),
                                                  *compressed_winhttp.values()]]]:
    temporary = output / ('.'+name+'.new')
    shutil.copyfile(path,temporary)
    temporary.replace(output / name)
    print(sha(output / name), name, flush=True)
print('Build log:',work / 'build.log',flush=True)
PY
