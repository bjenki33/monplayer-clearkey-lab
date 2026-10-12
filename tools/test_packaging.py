import hashlib
import struct
import unittest
import zipfile
from pathlib import Path
import sys

from patch_ipa import add_command, dylib_command, LOAD_PATH


class PackagingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with zipfile.ZipFile(sys.argv[-1]) as archive:
            cls.binary = archive.read('Payload/MonPlayer.app/MonPlayer')

    def testAddsOneExactDylibWithoutChangingCode(self):
        patched = add_command(self.binary, dylib_command(LOAD_PATH))
        before = struct.unpack_from('<II', self.binary, 16)
        after = struct.unpack_from('<II', patched, 16)
        self.assertEqual(after[0], before[0] + 1)
        end = 32 + before[1]
        self.assertEqual(self.binary[:16], patched[:16])
        self.assertEqual(self.binary[24:end], patched[24:end])
        self.assertEqual(self.binary[end + len(dylib_command(LOAD_PATH)):], patched[end + len(dylib_command(LOAD_PATH)):])
        self.assertEqual(len(self.binary), len(patched))
        self.assertIn(LOAD_PATH.encode(), patched[end:end + len(dylib_command(LOAD_PATH))])

    def testRefusesUnsupportedOrEncryptedBinary(self):
        with self.assertRaises(ValueError): add_command(b'not a Mach-O', dylib_command(LOAD_PATH))
        altered = bytearray(self.binary)
        cursor = 32
        for _ in range(struct.unpack_from('<I', altered, 16)[0]):
            cmd, length = struct.unpack_from('<II', altered, cursor)
            if cmd == 0x2c:
                struct.pack_into('<I', altered, cursor + 16, 1); break
            cursor += length
        with self.assertRaises(ValueError): add_command(bytes(altered), dylib_command(LOAD_PATH))

    def testRefusesInsufficientAndOccupiedHeaderPadding(self):
        with self.assertRaises(ValueError): add_command(self.binary, dylib_command('x' * 8192))
        altered = bytearray(self.binary)
        altered[32 + struct.unpack_from('<I', altered, 20)[0]] = 1
        with self.assertRaises(ValueError): add_command(bytes(altered), dylib_command(LOAD_PATH))


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(PackagingTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
