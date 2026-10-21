"""Remove foreign encoders from the pinned libvips source before compiling.

libvips has per-format loader flags but no decoder-only option. Loader helper
code and native image disk-spill stay intact; foreign saver operations do not.
"""
import pathlib,re,shutil
root=pathlib.Path('/src/vips/libvips/foreign')
meson=root/'meson.build'
source=meson.read_text()
source=re.sub(r"^\s*'(?!vipssave\.c)[^']*save\.c',\n",'',source,flags=re.M)
for helper in ('vips2tiff.c','vips2magick.c'):
    source=re.sub(r"^\s*'"+re.escape(helper)+r"',\n",'',source,flags=re.M)
meson.write_text(source)
foreign=root/'foreign.c'
source=foreign.read_text()
source=re.sub(r'^\s*vips_foreign_save_(?!vips)\w+_get_type\(\);\n','',source,flags=re.M)
source=source.replace('\tvips_foreign_print_matrix_get_type();', '')
foreign.write_text(source)
# vips' reader uses only JxlDecoder functions. The upstream unified pkg-config
# file otherwise pulls its encoder and Brotli's encoder into the runtime.
pc=pathlib.Path('/work/deps/lib/pkgconfig/libjxl.pc')
pc.write_text(pc.read_text().replace('-ljxl ','-ljxl_dec -ljxl_cms ').replace('-ljxl\n','-ljxl_dec -ljxl_cms\n'))
# Upstream builds this public decoder target but installs only the combined
# library. Install its output ourselves without modifying decoder sources.
for library in pathlib.Path('/work/jpeg-xl/lib').glob('libjxl_dec.so*'):
    shutil.copy2(library, pathlib.Path('/work/deps/lib') / library.name, follow_symlinks=False)

# Decoder runtime does not ship libvips CLI tools, test encoders or fuzzers.
meson=pathlib.Path("/src/vips/meson.build")
source=meson.read_text()
for directory in ("test", "fuzz", "tools"):
    source=source.replace("subdir('"+directory+"')", "# decoder-only: omit "+directory)
meson.write_text(source)
