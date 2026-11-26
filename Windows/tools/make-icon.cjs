// Repackage the original Mac application's PNG icon representations as an ICO.
// No redraw or image dependencies: both native apps use the same brand artwork.
const fs = require('node:fs');
const path = require('node:path');
const input = fs.readFileSync(path.join(__dirname, '../../Resources/AppIcon.icns'));
if (input.toString('ascii', 0, 4) !== 'icns') throw new Error('Invalid source icon');
const images = new Map();
for (let p = 8; p + 8 <= input.length;) {
	const length = input.readUInt32BE(p + 4);
	if (length < 8 || p + length > input.length) throw new Error('Invalid ICNS chunk');
	const data = input.subarray(p + 8, p + length);
	if (data.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) {
		const width = data.readUInt32BE(16), height = data.readUInt32BE(20);
		if (width === height && width <= 256) images.set(width, data);
	}
	p += length;
}
if (!images.has(256)) throw new Error('Missing 256-pixel source icon');
const entries = [...images.entries()].sort((a, b) => a[0] - b[0]);
const header = Buffer.alloc(6 + 16 * entries.length);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(entries.length, 4);
let offset = header.length;
entries.forEach(([size, data], i) => {
	const p = 6 + 16 * i;
	header[p] = header[p + 1] = size === 256 ? 0 : size;
	header.writeUInt16LE(1, p + 4);
	header.writeUInt16LE(32, p + 6);
	header.writeUInt32LE(data.length, p + 8);
	header.writeUInt32LE(offset, p + 12);
	offset += data.length;
});
const destination = path.join(__dirname, '../Resources/App.ico');
fs.mkdirSync(path.dirname(destination), { recursive: true });
fs.writeFileSync(destination, Buffer.concat([header, ...entries.map(([, data]) => data)]));
console.log(`Created native icon (${entries.map(([size]) => size).join(', ')} px)`);
