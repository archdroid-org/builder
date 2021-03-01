# Builder

A very basic bash script to automatically build packages from
a given github repository and upload them to a web server, git
repository or gh releases repository. While the script gets the job
done for the purpose of archdroid repo it is far from complete and
robust, eg: doesn't handles dependency build order, etc...

Improvements are welcome!

## Usage

First, for simplicity this script was made to run on the same
architecture of the packages that are going to be built (doesn't
supports chrooting yet). Also, make sure that the user which will
execute this script to build packages has sudo access. Install the
sudo package and set the wheel group as follows:

**cat /etc/sudoers.d/wheel**
```
%wheel ALL=(ALL) NOPASSWD: ALL
```

**Make the user is part of the wheel group:**
```sh
sudo usermod -aG wheel my-build-username
```

Clone this repository to a directory of your liking.
On a terminal switch to the directory containing the build.sh script,
execute it and it will ask you some questions like:

* reponame (as used on the /etc/pacman.conf entry eg: [archlinuxdroid]),
* git repository where PKGBUILD recipes reside eg:
  https://github.com/myuser/mypkgbuilds

Then it will offer you three different methods of uploading the built
packages for public access:

**WebServer (recommended):**
* hostname in ssh format where the packages are going to be
  uploaded, eg: mywebserver.com:/path/to/public/packages
* webserver name to properly generate the sample repo definitions for
  /etc/pacman.conf, eg: http://mywebserver.com

**GitHub repository:**
* gh repository where the builded packages will be commited, eg:
  git@github.com:myuser/mybuilds
* The committer username and e-mail.

**GitHub Releases repository (recommended):**
* gh repository where the builded packages are going to be
  uploaded using the gh releases functionality.
* Username or organization that contains the repository.
* The name of the repository itself.
* A user token that has access to the given repository using the
  github api (https://github.com/settings/tokens).

Once you have entered the proper information a config.ini file will be
generated along the build.sh script with content similar to:


```ini
reponame=myreponame
hostname=mywebserver.com:/path/to/public/packages
webserver=http://mywebserver.com
pkgbuilds_repo=https://github.com/myuser/mypkgbuilds
git_repo=git@github.com:myuser/mybuilds
git_username=myuser
git_email=myuser@some-email.com
gh_release_owner=myuser
gh_release_repo=myreleasebuilds
gh_release_token=1234567890111213141516171819abcde123456f
```

If you choose just one of the upload methods and want to setup another
one, you can do it by running one of the following subcommands:

```
setupgh     (Re)configure a github repository mirror
setupghr    (Re)configure a github repository for releases as mirror
setupweb    (Re)configure a webserver as mirror
```

As an example: **./build.sh setupghr**

Once everthing is setup you can start testing the build process by
running:

```sh
./build.sh build
```

## Setting Upload Access

To let the builder automatically upload packages to the defined
webserver (eg: mywebserver.com:/path/to/public/packages), git repo,
or git releases repo,  you would need to setup some ssh keys on your
remote server or git provider (check: https://wiki.archlinux.org/index.php/SSH_keys).
Ideally your local ssh key should not contain a passphrase to prevent
the builder script from asking for a password everytime, unless you
plan to execute the build script manually. You can configure the ssh
client to pick the proper ssh key setting a ~/.ssh/config file on the
user that is going to execute the build script as follows:

**~/.ssh/config**
```
Host mywebserver.com
    User some-user-with-access-to-webserver-files
    IdentityFile ~/.ssh/mywebserver_id
    IdentitiesOnly yes

Host github.com
    User git
    IdentityFile ~/.ssh/mygitrepos_id
    IdentitiesOnly yes
```

Finally, if you are going to use a github repository and the releases
functionality, you will need a token which can be generated from
https://github.com/settings/tokens

And of course! make sure to keep this keys and token safe, don't
commit them to a public repository by mistake ;)

## Running periodic builds with Cronie

Cronie is a service that implements the cron jobs mechanism, one could
also use systemd timers but crons are easy to define:

First install cronie:
```sh
sudo pacman -S cronie
sudo systemctl enable cronie
sudo systemctl start cronie
```

Then add a cron entry:
```sh
crontab -e

# Write something like
*/30 * * * * /path/to/build.sh build > /path/to/build.log 2>&1
```

This cron entry will execute the builder every 30 minutes. The builder
script will fetch any PKGBUILD changes from the specified git repository
and build them if necessary.

## Skipping Packages

You can tell the builder to skip certain packages from getting built
by adding a file named "skip" in the same directory where build.sh
resides  and adding all the package names you want to skip one per line.

**Example:**
```
some-problematic-package
other-package
```

## Commands supported by build.sh

```
Helper script to maintain an archlinux repo.

COMMANDS
  setup       Initialize the system for building.
  setupgh     (Re)configure a github repository mirror
  setupghr    (Re)configure a github repository for releases as mirror
  setupweb    (Re)configure a webserver as mirror
  config-get  Gets the value of an option on the config.ini.
              Params: <option-name>
  config-get  Set the value of an option on the config.ini.
              Params: <option-name> <option-value>
  clean       Remove all packages locally and remotely.
  build       Build outdated or missing packages and sync to server.
  buildpkg    Build a single package without syncing.
              Params: <package-name>
  addpkgs     Generate repo databases and upload sync to server.
  pkgver      Get a package names with version.
              Params: <package-name>
  repodef     View pacman.conf repo sample definition.
  help        Print this help.
```
