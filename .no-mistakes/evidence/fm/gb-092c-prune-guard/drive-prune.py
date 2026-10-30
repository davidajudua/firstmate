import os, subprocess, tempfile, pathlib, shutil
root=pathlib.Path.cwd()
lab=pathlib.Path(tempfile.mkdtemp(prefix='.prune-live-',dir=root))
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('GIT_'): env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Live Test',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Live Test',GIT_COMMITTER_EMAIL='test@example.invalid',FM_HOME=str(lab),FM_ROOT_OVERRIDE=str(root))
def run(*args):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    if p.returncode: raise RuntimeError(f'{args}: {p.stdout}')
    return p.stdout.strip()
def git(*args):return run('git',*args)
try:
    remote=lab/'remote.git'; clone=lab/'projects'/'demo'; clone.parent.mkdir()
    git('init','--bare','--initial-branch=main',str(remote))
    git('clone',str(remote),str(clone))
    def g(*a):return git('-C',str(clone),*a)
    def commit(text):
        (clone/'work.txt').write_text(text)
        g('add','work.txt');g('commit','-m',text)
        return g('rev-parse','HEAD')
    commit('base');g('push','-u','origin','main')
    g('checkout','-b','fully-pushed');pushed=commit('fully pushed work');g('push','-u','origin','fully-pushed')
    g('checkout','main');g('merge','--squash','fully-pushed');g('commit','-m','squash');g('push','origin','main')
    g('checkout','-b','unpushed');commit('pushed earlier');g('push','-u','origin','unpushed');unpublished=commit('commit after last push')
    g('checkout','main');git('--git-dir',str(remote),'update-ref','-d','refs/heads/fully-pushed');git('--git-dir',str(remote),'update-ref','-d','refs/heads/unpushed')
    print('Before sync (remote branches deleted, local tracking refs still present):\n'+g('branch','-vv'))
    print('Fully pushed tip is absent from current remote main:',subprocess.run(['git','-C',str(clone),'merge-base','--is-ancestor',pushed,'origin/main'],env=env).returncode==1)
    print('\nFirst actual fleet-sync invocation:\n'+run(env.get('PRUNE_SYNC_SCRIPT',str(root/'bin/fm-fleet-sync.sh')),'demo'))
    assert g('rev-parse','unpushed')==unpublished
    assert 'fully-pushed' not in g('branch','--format=%(refname:short)').splitlines()
    print('Persisted branches:\n'+g('branch','-vv'))
    print('Preserved commit:',g('log','-1','--format=%H %s','unpushed'))
    print('\nSecond actual fleet-sync invocation after the upstream snapshot is gone:\n'+run(env.get('PRUNE_SYNC_SCRIPT',str(root/'bin/fm-fleet-sync.sh')),'demo'))
    assert g('rev-parse','unpushed')==unpublished
    print('Repeated sync preserved exact unpublished tip:',unpublished)
    g('checkout','-b','already-gone');commit('prior fetch unknown push');g('push','-u','origin','already-gone');unknown=g('rev-parse','HEAD');g('checkout','main');g('push','origin','--delete','already-gone');g('fetch','--prune','origin')
    print('\nActual fleet-sync after an independent fetch already removed upstream:\n'+run(env.get('PRUNE_SYNC_SCRIPT',str(root/'bin/fm-fleet-sync.sh')),'demo'))
    assert g('rev-parse','already-gone')==unknown
    print('Unknown prior push conservatively preserved:',unknown)
finally:
    shutil.rmtree(lab)
