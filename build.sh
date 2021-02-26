#!/bin/bash
#
# Script to make it easier to maintain an ArchLinux packages repository.
#

cd "$(dirname "$0")" || exit

# Prevent running script more than once
exec 100>running.lock || exit 1
flock -w 3 100 || exit 1
trap 'rm -f running.lock' EXIT

if ! which ping > /dev/null 2>&1 ; then
  echo "The ping command is required to check internet connection."
  exit 1
fi

if ! ping -c1 8.8.8.8 > /dev/null 2>&1 ; then
  echo "Internet connection is required"
  exit 1
fi


if ! which repo-add > /dev/null 2>&1 ; then
  echo "The pacman repo-add tools is required."
  exit 1
fi

if ! which git > /dev/null 2>&1 ; then
  echo "Git is required to use this script."
  exit 1
fi

if ! which sshfs > /dev/null 2>&1 ; then
  echo "SSHFS is required."
  exit 1
fi

if ! which rsync > /dev/null 2>&1 ; then
  echo "rsync is required."
  exit 1
fi

setup_repo(){
  echo "Please enter the repository name that will be used on pacman.conf."
  echo -n "Name: "
  read reponame
  echo "$reponame" > reponame

  if [ ! -e "packages" ]; then
    echo "Enter the url of the git repo containing PKGBUILD scripts."
    echo -n "Repo: "
    read repo_url

    git clone "$repo_url" packages

    echo "Package build scripts cloned!"

    echo "Select the kind of repository where packages are going "
    echo -n "to be uploaded: (g)it, (w)ebserver or (b)oth [g/w/B]: "

    read answer

    case $answer in
      'g' | 'G' )
        setup_git_repo
        ;;
      'w' | 'W' )
        setup_webserver_repo
        ;;
      * )
        setup_git_repo
        setup_webserver_repo
        ::
    esac
  else
    cd packages
    git restore .
    git pull
    cd ..
  fi
}

setup_webserver_repo(){
  if [ -e "hostname" ]; then
    echo "A webserver repository is already setup do you want to"
    echo -n "remove it and set a new repository path? [y/N]: "

    read answer

    case $answer in
      'y' | 'Y' )
        echo "Removing old webserver repository..."
        rm -f hostname
        rm -f webserver
        ;;
      'n' | 'N' | * )
        return
        ;;
    esac
  fi

  echo "Please enter the ssh hostname:path where packages will be uploaded."
  echo -n "Host: "
  read hostname_path
  echo "$hostname_path" > hostname

  echo "Please enter the http web server address."
  echo -n "Address: "
  read address
  echo "$address" > webserver
}

setup_git_repo(){
  if [ -e "git-repo" ]; then
    echo "A git repository is already setup do you want to remove it"
    echo -n "and set a new repository path? [y/N]: "

    read answer

    case $answer in
      'y' | 'Y' )
        echo "Removing old git repository..."
        rm -rf git-repo
        ;;
      'n' | 'N' | * )
        return
        ;;
    esac
  fi

  local cloned="0"

  while [ "$cloned" != "1" ]; do
    echo "Enter the ssh path to a git repo to host the packages."
    echo -n "Repo: "
    read repo_url

    git clone "$repo_url" git-repo

    if [ "$?" != "0" ]  ; then
      continue
    fi

    echo "Package build scripts cloned!"

    echo "Please enter the username that will appear on commits."
    echo -n "Username: "
    read username

    echo "Please enter the e-mail for the username."
    echo -n "E-mail: "
    read email

    cd git-repo

    git config user.name "$username"
    git config user.email "$email"
    git config credential.helper store
    git config push.default simple

    cd ..

    cloned="1"
  done
}

clean_repo(){
  local ARCH=$(uname -m)
  if [ -e "$ARCH" ]; then
    rm -r "$ARCH"
  fi

  if [ -e "git-repo" ]; then
    cd git-repo

    if [ -e "$ARCH" ]; then
      rm -rf "$ARCH"
    fi

    mv .git/config config
    rm -rf .git

    git init
    mv config .git/config

    if [ -e "README.md" ]; then
      git add README.md
    fi

    if [ -e ".gitignore" ]; then
      git add .gitignore
    fi

    if [ -e ".gitattributes" ]; then
      git add .gitattributes
    fi

    git commit -m "Cleaned repository"
    git push -f origin

    cd ..
  fi
}

sync_repo(){
  local ARCH=$(uname -m)
  local REPONAME=$(cat reponame)

  if [ -e "hostname"  ]; then
    if [ ! -e "upload" ]; then
      mkdir upload
    else
      rm -rf upload
      mkdir upload
    fi

    sshfs "$(cat hostname)" upload
    if [ ! -e "upload/$REPONAME" ]; then
      mkdir -p "upload/$REPONAME/$ARCH"
    fi

    # upload first new packages only
    mv "$ARCH"/"$REPONAME".db .
    mv "$ARCH"/"$REPONAME".files .

    rsync -av "$ARCH/" "upload/$REPONAME/$ARCH/"

    # upload new databases
    mv "$REPONAME".db "$ARCH/"
    mv "$REPONAME".files "$ARCH/"

    rsync -av "$ARCH/" "upload/$REPONAME/$ARCH/"

    # delete old packages
    rsync -av --delete "$ARCH/" "upload/$REPONAME/$ARCH/"

    umount upload
  fi

  if [ -e "git-repo" ]; then
    cd git-repo

    if [ ! -e "$ARCH" ]; then
      mkdir "$ARCH"
      echo "" > "$ARCH/.gitkeep"
      git add "$ARCH/.gitkeep"
      git commit -m "Added architecture $ARCH"
    fi

    # Remove old repo files from git history
    for file in $(echo "${ARCH}/${REPONAME}."{db,files} | xargs) ; do
      if [ -e "$file" ]; then
        FILTER_BRANCH_SQUELCH_WARNING=1 \
        git filter-branch --force --index-filter \
          "git rm --cached --ignore-unmatch $file" \
          --prune-empty --tag-name-filter cat -- --all
      fi
    done

    # Files on github can not exceed 100mb
    rsync -av --delete \
      --max-size=100m \
      --filter='P .gitkeep' \
      "../$ARCH/" "$ARCH/"

    # check modified packages
    git status --short | awk '{print $1 " " $2}' | \
    while read -r line ; do
      local action=$(echo $line | cut -d" " -f1)
      local file=$(echo $line | cut -d" " -f2)

      if [ "$action" = "M" ]; then
        git add "$file"
        git commit -m "Updated $file"
      fi
    done

    # check for deleted packages
    git status --short | awk '{print $1 " " $2}' | \
    while read -r line ; do
      local action=$(echo $line | cut -d" " -f1)
      local file=$(echo $line | cut -d" " -f2)

      if [ "$action" = "D" ]; then
        git rm "$file"
        git commit -m "Removed file $file"

        # Remove whole file from git history
        FILTER_BRANCH_SQUELCH_WARNING=1 \
        git filter-branch --force --index-filter \
          "git rm --cached --ignore-unmatch $file" \
          --prune-empty --tag-name-filter cat -- --all
      fi
    done

    # now check for packages to add
    git status --short | awk '{print $1 " " $2}' | \
    while read -r line ; do
      local action=$(echo $line | cut -d" " -f1)
      local file=$(echo $line | cut -d" " -f2)

      if [ "$action" = "??" ]; then
        git add "$file"
        git commit -m "Added $file"

        # a push per file
        git push -f origin
      fi
    done

    # push any pending changes
    git push -f origin

    cd ..
  fi
}

add_packages(){
  local ARCH=$(uname -m)
  local REPONAME=$(cat reponame)

  rm "$ARCH"/"$REPONAME".*

  repo-add --new --prevent-downgrade "$ARCH"/"$REPONAME".db.tar.gz \
    $(ls "$ARCH"/* | grep -v $REPONAME.db | grep -v $REPONAME.files)

  rm "$ARCH"/"$REPONAME".db
  cp "$ARCH"/"$REPONAME".db.tar.gz "$ARCH"/"$REPONAME".db

  rm "$ARCH"/"$REPONAME".files
  cp "$ARCH"/"$REPONAME".files.tar.gz "$ARCH"/"$REPONAME".files

  rm "$ARCH"/"$REPONAME".db.tar.gz
  rm "$ARCH"/"$REPONAME".files.tar.gz
}

repo_usage(){
  echo "# Example usage of this repository on /etc/pacman.conf"

  if [ -e "reponame" ]; then
    echo "[$(cat reponame)]"
  else
    echo "[reponame]"
  fi

  echo "SigLevel = Optional TrustedOnly"

  if [ -e "hostname" ]; then
    if [ -e "webserver" ]; then
      echo "Server = $(cat webserver)/\$repo/\$arch"
    else
      echo "Server = http://localhost/\$repo/\$arch"
    fi
  fi

  if [ -e "git-repo" ]; then
    cd git-repo
    #username=$(git config --get user.name)
    echo "Server = https://raw.githubusercontent.com/\$username/\$repo/main/\$arch"
    cd ..
  fi
}

if [ ! -e "packages" ]; then
  echo "You must run the setup to initialize the PKGBUILDs repository."
  echo -n "Do you want to run the setup now? [y/n]: "
  read run_setup
  if [ "$run_setup" = "y" ]; then
    setup_repo
    echo "Setup complete, next time this script is run will start building."
    exit 0
  else
    exit 1
  fi
fi


case $1 in
  'setup' )
    setup_repo
    exit
    ;;
  'setupgit' )
    setup_git_repo
    exit
    ;;
  'clean' )
    clean_repo
    exit
    ;;
  'addpkgs' )
    add_packages
    sync_repo
    exit
    ;;
  'repodef' )
    repo_usage
    exit
    ;;
  'build' )
    echo "Started on: $(date)"
    sudo pacman -Suy --noconfirm
    echo "Starting build process..."
    ;;
  * )
    echo "Helper script to maintain an archlinux repo."
    echo ""
    echo "COMMANDS"
    echo "  setup    initialize the system for building"
    echo "  setupgit (re)configure a github repository mirror"
    echo "  clean    remove all packages"
    echo "  build    build outdated or missing packages and sync to server."
    echo "  addpkgs  generate repo databases and upload sync to server"
    echo "  repodef  view pacman.conf repo sample definition"
    echo "  help     print this help"
    exit
    ;;
esac


ARCH=$(uname -m)
PACKAGES_BUILT=()
REPONAME=$(cat reponame)

if [ ! -e "$ARCH" ]; then
  mkdir "$ARCH"
fi

#
# Update PKGBUILDs repository
#
cd packages
git checkout master
git restore .
git pull
cd ..

#
# Make a list of packages to build
#
if [ -e "skip" ]; then
  packages=(
    $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2 | grep -v -f skip)
  )
else
  packages=(
    $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2)
  )
fi

get_packages(){
  if [ ! -e "packages/$1/PKGBUILD" ]; then
    echo "$1"
    return 1
  fi

  cd packages/"$1"

  local package_info=""
  if [ ! -e .SRCINFO ]; then
    # Update pkgver if possible (this means the package may be a VCS)
    makepkg -s --noconfirm --nobuild --clean > /dev/null
    rm -rf src pkg
    # Get package info
    package_info=$(makepkg -s --noconfirm --printsrcinfo)
  else
    # Use already provided .SRCINFO which is faster
    package_info=$(cat .SRCINFO)
  fi

  local packages=()
  local action="name"

  local pkgname=""
  local pkgver=""
  local pkgrel=""
  local epoch=""

  echo "$package_info" | while read line; do
    local name=$(echo $line | cut -d"=" -f1 | sed "s/ //g")
    local value=$(echo $line | cut -d"=" -f2 | sed "s/ //g")

    if [ "$action" = "name" -a "$name" = "pkgbase" ]; then
      if [[ ! " ${packages[@]} " =~ " $value " ]]; then
        packages+=("$value")
        pkgname="$value"
        action="version"
      fi
    elif [ "$action" = "version" -a "$name" = "pkgver" ]; then
      pkgver="$value"
      action="release"
    elif [ "$action" = "release" -a "$name" = "pkgrel" ]; then
      pkgrel="$value"
      action="epoch"
    elif [ "$action" = "epoch" -a "$name" = "epoch" ]; then
      epoch="$value"
      action="done"
    elif [ "$action" = "epoch" -a "$name" = "arch" ]; then
      action="done"
    elif [ "$action" = "pkgname" -a "$name" = "pkgname" ]; then
      if [[ ! " ${packages[@]} " =~ " $value " ]]; then
        packages+=("$value")
        if [ "$epoch" != "" ]; then
          echo "$value-${epoch}:$pkgver-$pkgrel"
        else
          echo "$value-$pkgver-$pkgrel"
        fi
      fi
    fi

    if [ "$action" = "done" -a "$pkgname" != "" ]; then
      if [ "$epoch" != "" ]; then
        echo "$pkgname-${epoch}:$pkgver-$pkgrel"
      else
        echo "$pkgname-$pkgver-$pkgrel"
      fi
      action="pkgname"
    fi
  done

  cd ../../
}

build_if_needed(){
  if [ ! -e "packages/$1/PKGBUILD" ]; then
    rm -vf "$ARCH"/"$1"*".pkg.tar."*
    rm -rf "packages/$1"
    echo "Package removed from repository."
    return 3
  fi

  found=$(ls "$ARCH" | grep "$2-$ARCH.pkg.tar.*")
  if [ "$found" = "" ]; then
    echo "Building $2..."
    cd packages/"$1"

    makepkg -s --noconfirm --clean --cleanbuild > build.log 2>&1
    make_status=$?
    if [ $make_status -eq 0 ]; then
      rm -vf ../../"$ARCH"/"$1"*".pkg.tar."*
      cp *.pkg.tar.* ../../"$ARCH"/
      rm *.pkg.tar.*
    else
      echo "Error: could not build, see packages/$1/build.log for details"
    fi

    cd ../../

    if [ "$make_status" != "0" ]; then
      return 2
    else
      return 1
    fi
  else
    echo "$2 already built..."
    return 2
  fi
}

#
# Build packages not already built or outdated
#
for package in "${packages[@]}"; do
  names=$(get_packages "$package")
  for name in "$names"; do
    build_if_needed "$package" "$name"
    if [ $? -eq 1 ]; then
      PACKAGES_BUILT+=("$package")
    fi
  done
done

#
# Upload built packages
#
if [ ${#PACKAGES_BUILT[@]} -gt 0 ]; then
  add_packages
  sync_repo
fi

echo "Ended on: $(date)"
