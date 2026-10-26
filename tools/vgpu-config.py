#!/usr/bin/env python3
import re
import sys

DEVICE_IDS = ("0x20C2", "0x2082")
TYPES = (
    (468, "GRID A100-4C", "0x1498", "0x100000000", "0xEC000000", "0x14000000", 10),
    (469, "GRID A100-5C", "0x1499", "0x140000000", "0x128000000", "0x18000000", 8),
    (470, "GRID A100-8C", "0x149A", "0x200000000", "0x1DC000000", "0x24000000", 5),
    (471, "GRID A100-10C", "0x149B", "0x280000000", "0x254000000", "0x2C000000", 4),
    (472, "GRID A100-20C", "0x149C", "0x500000000", "0x4AC000000", "0x54000000", 2),
    (473, "GRID A100-40C", "0x149D", "0xA00000000", "0x95C000000", "0xA4000000", 1),
)
TYPE_XML = """  <vgpuType id="%d" name="%s" class="Compute">
    <devId vendorId="0x10de" deviceId="0x20F1" subsystemVendorId="0x10de" subsystemId="%s"/>
    <profileSize>%s</profileSize>
    <framebuffer>%s</framebuffer>
    <fbReservation>%s</fbReservation>
    <numHeads>1</numHeads>
    <display width="4096" height="2400"/>
    <maxPixels>9216000</maxPixels>
    <mappableVideoSize>0x400000</mappableVideoSize>
    <frlConfig>0x3c</frlConfig>
    <cudaEnabled>1</cudaEnabled>
    <eccSupported>1</eccSupported>
    <multiVgpuSupported>1</multiVgpuSupported>
    <multiVgpuExclusive>0</multiVgpuExclusive>
    <encoderCapacity>0x64</encoderCapacity>
    <bar1Length>0x100</bar1Length>
    <frame_rate_limiter>1</frame_rate_limiter>
    <license>VCS;QVDWS</license>
    <gpuDirectSupported>1</gpuDirectSupported>
  </vgpuType>
"""
SUPPORTED_XML = """    <supportedVgpu vgpuId="%d">
      <maxVgpus>%d</maxVgpus>
      <digest type="signature">%s</digest>
    </supportedVgpu>
"""

src, out = sys.argv[1:3]
xml = open(src, encoding="utf-8").read()
have = set(int(i) for i in re.findall(r'<vgpuType id="(\d+)"', xml))
clash = have & set(t[0] for t in TYPES)
if clash:
    sys.exit("type ids %s already defined in %s" % (sorted(clash), src))
for dev in DEVICE_IDS:
    if re.search(r'<pgpu[^>]*>\s*<devId[^>]*deviceId="%s"' % dev, xml, re.I):
        sys.exit("%s already has a <pgpu> block" % dev)

types = "".join(TYPE_XML % t[:6] for t in TYPES)
entries = "".join(SUPPORTED_XML % (t[0], t[6], "00" * 128) for t in TYPES)
pgpus = "".join('  <pgpu fractionalMultiVgpu="1" hostVgpuMode="sriov">\n'
                '    <devId vendorId="0x10de" deviceId="%s" subsystemVendorId="0x10de" subsystemId="0x0"/>\n'
                '%s  </pgpu>\n' % (dev, entries) for dev in DEVICE_IDS)
first = xml.index("  <vgpuType ")
last = xml.rindex("</pgpu>\n") + len("</pgpu>\n")
xml = xml[:first] + types + xml[first:last] + pgpus + xml[last:]
open(out, "w", encoding="utf-8", newline="\n").write(xml)
print("added %d A100 compute types for %s" % (len(TYPES), ", ".join(DEVICE_IDS)))
