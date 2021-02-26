# Builder

A very basic bash script to automatically build packages from
a given github repository and upload them to a web server. While
the script gets the job done for the purpose of archdroid repo
it is far from complete and robust.

## Usage

Frist, clone this repository to a directory of your liking.
Run the build.sh script and it will ask you some questions regarding
the git repository where pkgbuilds reside, reponame, web server, etc.

Once you have entered the proper information you can add a crontab
entry to your system as follows:

```sh
*/30 * * * * /path/to/build.sh build > /path/to/build.log 2>&1
```

This cron entry will execute the builder every 30 minutes.

## Skipping Packages

You can tell the builder to skip certain packages from getting built
by adding a file named "skip" in the same directory where build.sh
resides  and adding all the package names you want to skip one per line.
