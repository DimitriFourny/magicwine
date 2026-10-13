#!/bin/bash
# Rebuild Wine 11's native and 32/64-bit PE winemac/ntdll Metal ABI modules.
# Requires Apple clang 21.0.0 (clang-2100.3.34.2), macOS SDK 26.5, make,
# flex, Python 3 and both x86_64/i686-w64-mingw32 GCC toolchains.
# The shipped corresponding-source archive supports the same command offline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import gzip, hashlib, json, os, pathlib, shutil, subprocess, sys, tarfile, tempfile, zlib
root = pathlib.Path(sys.argv[1])
component = 'winemac-wine11.0-metal.1'
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
link_hashes = {'win32u.so': '5686c667977ab6d4ea932ea53a2a7b73e51c936988118707b85c7619db1dfb98'}
original_native_ntdll_hash = 'dfb9d4d4d6e7fd3dc537c1bacd69cb3a6bb46ae98311bb5358df3c4eab470c3f'
original_hash = '7687c4095ea6dba1761052ac19d46db3409a36f2bc827b79c6e32bf779df59f4'
original_pe_hashes = {'x86_64':'9c52f24507b692ef0fcc0dc5439b8bee63f869f04ef38494bf52e52ddfbfecf0',
                      'i386':'200a8cd50084d1bd70511681082fbe152a585a8638e84a5aafe8148a8248cda5'}
original_ntdll_hashes = {'x86_64':'d63d10c77a55105d68bf1935ff10137d2ab5e8a4c6ae329aee599f17524b2755',
                        'i386':'bac6f2d9434860d09a696dcdcd5f85631e19fd4f9409b3a39828841b7a40c089'}
epoch = 1768262400
sdk = pathlib.Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk')
if not sdk.is_dir(): raise SystemExit('macOS SDK 26.5 is required; no SDK/toolchain is installed by this script')
for tool in ('clang', 'make', 'bison', 'flex', 'patch', 'nm', 'otool', 'x86_64-w64-mingw32-gcc', 'i686-w64-mingw32-gcc'):
    if not shutil.which(tool): raise SystemExit('Missing prerequisite: ' + tool)
clang_version = subprocess.check_output(['clang', '--version'], text=True)
if 'clang-2100.3.34.2' not in clang_version: raise SystemExit('Pinned Apple clang-2100.3.34.2 is required')
env = os.environ.copy()
for key in ('CC','CXX','CFLAGS','CXXFLAGS','CPPFLAGS','LDFLAGS','CPATH','C_INCLUDE_PATH','CPLUS_INCLUDE_PATH','LIBRARY_PATH','WINEPREFIX','WINEARCH','SDKROOT','MACOSX_DEPLOYMENT_TARGET'):
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
inputs = work / 'source-inputs'
inputs.mkdir()
offline = root / 'source-inputs'
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
        for name,digest in link_hashes.items():
            member = tar.getmember('Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-unix/' + name)
            if not member.isfile(): raise SystemExit('Link input is not a regular file')
            (inputs / name).write_bytes(tar.extractfile(member).read())
            verify(inputs / name,digest)
with tarfile.open(source) as tar: tar.extractall(work, filter='data')
src = work / 'wine-wine-11.0'
run(['patch','--batch','--forward','--fuzz=0','-p1','-i',str(patch)],src)
build = work / 'build'
build.mkdir()
flags = '-O2 -g0 -arch x86_64 -isysroot ' + str(sdk) + ' -mmacosx-version-min=10.15 -ffile-prefix-map=' + str(work) + '=.'
run([str(src / 'configure'),'--build=x86_64-apple-darwin','--host=x86_64-apple-darwin',
     '--enable-archs=i386,x86_64','--disable-tests','--without-x','--without-freetype',
     'CC=clang -arch x86_64', 'CFLAGS=' + flags,
     'x86_64_CFLAGS=-O2 -g0 -ffile-prefix-map=' + str(work) + '=.',
     'i386_CFLAGS=-O2 -g0 -ffile-prefix-map=' + str(work) + '=.',
     'LDFLAGS=-arch x86_64 -isysroot ' + str(sdk) + ' -mmacosx-version-min=10.15'],build)
# Build the complete Unix driver and matching PE driver/ntdll modules.
# The native driver and ntdll retain the pinned stock win32u ABI.
units = sorted(p.stem for p in (src / 'dlls/winemac.drv').iterdir()
               if p.suffix == '.m' or (p.suffix == '.c' and '#pragma makedep unix' in p.read_text()))
objects = ['dlls/winemac.drv/' + unit + '.o' for unit in units]
native_ntdll = build / 'dlls/ntdll/ntdll.so'
run(['make','-j4',*objects,'dlls/ntdll/ntdll.so'],build)
frameworks = ['AppKit','Carbon','CoreVideo','Foundation','IOKit','Metal','OpenGL','QuartzCore','Security']
link = ['clang','-arch','x86_64','-isysroot',str(sdk),'-mmacosx-version-min=10.15','-dynamiclib',
        '-Wl,-headerpad_max_install_names','-Wl,-install_name,winemac.so','-o','winemac.so',*objects,
        str(native_ntdll),str(inputs / 'win32u.so')]
for framework in frameworks: link += ['-framework',framework]
run(link,build)
driver = build / 'winemac.so'
# Keep native linkage runtime-local, including the unchanged stock win32u input.
run(['install_name_tool','-change','win32u.so','@rpath/win32u.so',str(driver)],build)
pe_drivers = {arch:build / ('dlls/winemac.drv/' + arch + '-windows/winemac.drv') for arch in ('x86_64','i386')}
pe_ntdll = {arch:build / ('dlls/ntdll/' + arch + '-windows/ntdll.dll') for arch in ('x86_64','i386')}
run(['make','-j4',*[str(path.relative_to(build)) for path in [*pe_drivers.values(), *pe_ntdll.values()]]],build)
exports = subprocess.check_output(['nm','-gU',str(driver)],text=True)
required = ['macdrv_functions','magicwine_metal_bridge_v1',
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
payload = work / (component + '-source')
payload.mkdir()
shutil.copytree(inputs,payload / 'source-inputs')
for name in ('scripts/build-metal-wine.sh','patches/wine-metal-driver.patch'):
    target = payload / name
    target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(root / name,target)
shutil.copytree(src / 'dlls/winemac.drv',payload / 'patched-driver')
shutil.copytree(src / 'dlls/ntdll',payload / 'patched-ntdll')
license_text = ('MagicWine Metal Wine support: public Wine 11 native and PE winemac/ntdll modules\n'
                'with the public Unix-call entry point, native pthread TLS, and D3DMetal Nt ABI.\n'
                'The MagicWine D3DMetal/DXMT client-surface bridge is LGPL-2.1-or-later.\n'
                'ABI reference: Whisky-App/wine a92f7f06c4cff7291578e58eb95284b00e322799,\n'
                'dlls/winemac.drv/macdrv_main.c and macdrv.h (LGPL-2.1-or-later).\n'
                'Native ABI source references: CodeWeavers CrossOver 26.1 public source mirror,\n'
                'rnowak/wine-crossover-sources b4f3c510a1808e6e32fb99e9bc11fa46ccc207dc;\n'
                'Alien4042x/WineForge a342f4aeb23d719339f444b9e94e06ecf0ff1a14 (LGPL-2.1-or-later).\n'
                'No proprietary CrossOver or Apple binaries are included.\n'
                'Original Wine file copyright notices are retained in the corresponding source.\n'
                'Rebuild offline: extract the adjacent -source.tar.gz and run bash scripts/build-metal-wine.sh.\n'
                'The source bundle includes the complete original Wine 11 source archive,\n'
                'patch, recipe, and public pinned native link inputs.\n\n' + (src / 'COPYING.LIB').read_text())
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
metadata = {'component':component,'source':{'url':source_url,'sha256':source_hash},
            'stock':{'url':stock_url,'sha256':stock_hash,'original_driver_sha256':original_hash,
                     'original_pe_sha256':original_pe_hashes,'original_ntdll_sha256':original_ntdll_hashes,
                     'original_native_ntdll_sha256':original_native_ntdll_hash},
            'patch_sha256':patch_hash,'link_inputs_sha256':link_hashes,
            'metal_contract':{'url':'https://github.com/Whisky-App/wine/blob/a92f7f06c4cff7291578e58eb95284b00e322799/dlls/winemac.drv/macdrv_main.c',
                              'table_slots':24,'window_data_bytes':120,'client_view_offset':24},
            'dxmt_contract':{'url':'https://github.com/3Shain/dxmt/blob/v0.80/src/winemetal/unix/winemetal_unix.c',
                             'consumed_table_prefix_slots':10},
            'pe_sha256':{arch:sha(path) for arch,path in pe_drivers.items()},
            'compressed_pe_sha256':{arch:sha(path) for arch,path in compressed_pe.items()},
            'ntdll_sha256':{arch:sha(path) for arch,path in pe_ntdll.items()},
            'compressed_ntdll_sha256':{arch:sha(path) for arch,path in compressed_ntdll.items()},
            'compiler':clang_version.strip(),'sdk':'26.5','deployment_target':'10.15',
            'source_date_epoch':epoch,'driver_sha256':sha(driver),
            'native_ntdll_sha256':sha(native_ntdll),
            'compressed_native_ntdll_sha256':sha(compressed_native_ntdll),
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
                  *[(path,path.name) for path in [*compressed_pe.values(), *compressed_ntdll.values()]]]:
    temporary = output / ('.'+name+'.new')
    shutil.copyfile(path,temporary)
    temporary.replace(output / name)
    print(sha(output / name), name, flush=True)
print('Build log:',work / 'build.log',flush=True)
PY
