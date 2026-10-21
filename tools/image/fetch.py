import hashlib,json,pathlib,tarfile,urllib.request
for name,entry in json.load(open('/build/sources.json')).items():
    print('Fetching '+name,flush=True)
    archive=pathlib.Path('/src')/('archive-'+name)
    with urllib.request.urlopen(entry['url'],timeout=120) as response,archive.open('wb') as out:
        while block:=response.read(1024*1024): out.write(block)
    if hashlib.sha256(archive.read_bytes()).hexdigest()!=entry['sha256']: raise RuntimeError(name+' checksum mismatch')
    root=pathlib.Path('/src')/name;root.mkdir()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            parts=pathlib.PurePosixPath(member.name).parts
            if len(parts)<2:continue
            member.name=str(pathlib.PurePosixPath(*parts[1:]))
            if '..' in pathlib.PurePosixPath(member.name).parts or member.name.startswith('/'): raise RuntimeError('unsafe archive path')
            tar.extract(member,root)
    archive.unlink()
