// 04_storage.mjs: file storage protected by the same RLS model as tables.
//
// Files go into "buckets". The bytes live in object storage (S3-compatible). Each file's
// metadata is a row in storage.objects, and the policies in migration 3 decide who can
// read and write which paths. Convention used here: avatars/<user-id>/<filename>
//
// Run (from the 03-supabase folder; run lesson 02 first so the users exist):
//   npm run lesson:storage

import { signedInClient, section, show } from './_supabase.mjs';

const { client: ana, user: anaUser } = await signedInClient('ana@example.com', 'ana');
const { client: ben } = await signedInClient('ben@example.com', 'ben');

// A real 1x1 pixel PNG, so we don't need any files on disk.
const tinyPng = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==',
  'base64',
);
const anaPath = `${anaUser.id}/avatar.png`;

// -------------------------------------------------------------------------------------
section('1. Upload into your own folder');
show('ana uploads avatars/<ana-id>/avatar.png', await ana.storage.from('avatars')
  .upload(anaPath, tinyPng, { contentType: 'image/png', upsert: true }));
show('ana lists her folder', await ana.storage.from('avatars').list(anaUser.id)
  .then(({ data, error }) => ({ data: data?.map((f) => `${f.name} (${f.metadata?.size} bytes)`), error })));

const dl = await ana.storage.from('avatars').download(anaPath);
console.log(`  ana downloads it: ${dl.error ? 'ERROR ' + dl.error.message : `${dl.data.size} bytes, type ${dl.data.type}`}`);

show('ana saves the path on her profile', await ana.from('profiles')
  .update({ avatar_path: anaPath }).eq('id', anaUser.id).select('username, avatar_path'));

// -------------------------------------------------------------------------------------
section("2. Ben tries to touch ana's files");
const benDl = await ben.storage.from('avatars').download(anaPath);
console.log(`  ben downloads ana's avatar: ${benDl.error ? 'ERROR ' + (benDl.error.message || benDl.error.name || 'denied') : 'got it?!'}`);
show("ben uploads into ana's folder", await ben.storage.from('avatars')
  .upload(`${anaUser.id}/evil.png`, tinyPng, { contentType: 'image/png' }));
show("ben lists ana's folder", await ben.storage.from('avatars').list(anaUser.id));
console.log('  -> Listing shows [] rather than an error: same "invisible rows" behavior as tables.');

// -------------------------------------------------------------------------------------
section('3. Bucket rules: file type and size limits (set in migration 3)');
show('ana uploads a PDF (type not allowed)', await ana.storage.from('avatars')
  .upload(`${anaUser.id}/doc.pdf`, Buffer.from('%PDF-1.4'), { contentType: 'application/pdf' }));
show('ana uploads 2 MB (limit is 1 MB)', await ana.storage.from('avatars')
  .upload(`${anaUser.id}/big.png`, Buffer.alloc(2 * 1024 * 1024), { contentType: 'image/png' }));

// -------------------------------------------------------------------------------------
section('4. Sharing a private file: signed URLs');
const { data: signed } = await ana.storage.from('avatars').createSignedUrl(anaPath, 60);
const signedRes = await fetch(signed.signedUrl);
console.log(`  signed URL (valid 60 s): ${signed.signedUrl.slice(0, 80)}...`);
console.log(`  fetched with NO auth headers -> HTTP ${signedRes.status}, ${(await signedRes.arrayBuffer()).byteLength} bytes`);

const { data: pub } = ana.storage.from('avatars').getPublicUrl(anaPath);
const pubRes = await fetch(pub.publicUrl);
console.log(`  getPublicUrl() on a PRIVATE bucket -> HTTP ${pubRes.status}`);
console.log('  -> getPublicUrl only BUILDS a URL string. It works only for buckets with public = true.');

// -------------------------------------------------------------------------------------
section('5. Clean up');
show('ana removes her avatar', await ana.storage.from('avatars').remove([anaPath])
  .then(({ data, error }) => ({ data: data?.map((o) => o.name), error })));
await ana.from('profiles').update({ avatar_path: null }).eq('id', anaUser.id);
console.log(`
Production notes:
  - Public buckets: anyone with the URL can read (good for marketing images, CDN cached).
    Private buckets + signed URLs: user content.
  - Upload policies run on storage.objects, so the same auth.uid() patterns apply.
  - Large files: resumable uploads (TUS protocol). Existing tools: the S3-compatible endpoint.
  - Image resizing on the fly (transformations) is a paid hosted feature.

Next: npm run lesson:functions`);
