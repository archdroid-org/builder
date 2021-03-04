#!/bin/bash
#
# Script to make it easier to maintain an ArchLinux packages repository.
#

cd "$(dirname "$0")" || exit

CURRENT_DIR=$(pwd)

# Prevent running script more than once
exec 100>running.lock || exit 1
flock -w 3 100 || exit 1
trap 'rm -f running.lock' EXIT

# Check if required dependencies are met.
deps=(
    ping repo-add git curl
    sshfs rsync jq grep
    sed awk makepkg file
)

DEPENDENCIES=()
for dep in "${deps[@]}"; do
    command -v ${dep} 1>/dev/null 2>/dev/null || DEPENDENCIES+=("${dep}")
done

if [ "$DEPENDENCIES" != "" ]; then
    echo "Please install '${DEPENDENCIES[@]}' to use this script." 1>&2
    exit 1
fi

if ! ping -c1 8.8.8.8 > /dev/null 2>&1 ; then
  echo "Internet connection is required"
  exit 1
fi

# Store option in config.ini
# @param config_name
# @param config_value
config_write(){
  if [ -e "config.ini" ]; then
    if grep -q "${1}=" config.ini ; then
      sed -in "s/^${1}=.*\$/${1}=${2}/g" config.ini
      return
    fi
  fi

  echo "${1}=${2}" >> config.ini
}

# Get option from config.ini
# @param config_name
# @return value of config_name
config_get(){
  if [ -e "config.ini" ]; then
    grep -E "^${1}=" config.ini | sed "s/${1}=\(.*\)/\1/"
    return
  fi

  echo ""
}

setup_repo(){
  echo "Please enter the repository name that will be used on pacman.conf."
  echo -n "Name: "
  read reponame
  config_write reponame "$reponame"

  if [ ! -e "packages" ]; then
    echo "Enter the url of the git repo containing PKGBUILD scripts."
    echo -n "Repo: "
    read repo_url

    git clone "$repo_url" packages

    config_write pkgbuilds_repo "$repo_url"

    echo "Package build scripts cloned!"

    echo "Select the kind of repository where packages are going "
    echo -n "to be uploaded: (g)it, (r)github release, (w)ebserver or (a)ll [g/r/w/A]: "

    read answer

    case $answer in
      'g' | 'G' )
        setup_gh_repo
        ;;
      'r' | 'R' )
        setup_gh_release_repo
        ;;
      'w' | 'W' )
        setup_webserver_repo
        ;;
      * )
        setup_gh_repo
        setup_gh_release_repo
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
  if [ "$(config_get hostname)" != "" ]; then
    echo "A webserver repository is already setup do you want to"
    echo -n "overwrite it and set a new repository path? [y/N]: "

    read answer

    case $answer in
      'y' | 'Y' )
        continue
        ;;
      'n' | 'N' | * )
        return
        ;;
    esac
  fi

  echo "Please enter the ssh hostname:path where packages will be uploaded."
  echo -n "Host: "
  read hostname_path
  config_write hostname "$hostname_path"

  echo "Please enter the http web server address."
  echo -n "Address: "
  read address
  config_write webserver "$address"
}

setup_gh_repo(){
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

    config_write git_repo "$repo_url"

    echo "Package build scripts cloned!"

    echo "Please enter the username that will appear on commits."
    echo -n "Username: "
    read username

    echo "Please enter the e-mail for the username."
    echo -n "E-mail: "
    read email

    config_write git_username "$username"
    config_write git_email "$email"

    cd git-repo

    git config user.name "$username"
    git config user.email "$email"
    git config credential.helper store
    git config push.default simple

    cd ..

    cloned="1"
  done
}

setup_gh_release_repo(){
  if [ "$(config_get gh_release_owner)" != "" ]; then
    echo "A github release repository is already setup do you want"
    echo -n " to overwrite it and set a new repository path? [y/N]: "

    read answer

    case $answer in
      'y' | 'Y' )
        continue
        ;;
      'n' | 'N' | * )
        return
        ;;
    esac
  fi

  echo "Enter owner of github repository for releases."
  local answer=""
  while [ "$answer" = "" ]; do
    echo -n "Owner: "
    read answer
  done
  config_write gh_release_owner "$answer"

  echo "Enter github repository for releases."
  local answer=""
  while [ "$answer" = "" ]; do
    echo -n "Repo: "
    read answer
  done
  config_write gh_release_repo "$answer"

  echo "Enter the authentication token see (https://github.com/settings/tokens)."
  local answer=""
  while [ "$answer" = "" ]; do
    echo -n "Token: "
    read answer
  done
  config_write gh_release_token "$answer"
}

clean_repo(){
  # Delete files locally
  local ARCH=$(uname -m)
  if [ -e "$ARCH" ]; then
    rm -r "$ARCH"
  fi

  # Delete files from gh repo
  if [ -e "git-repo" ]; then
    cd git-repo

    if [ -e "$ARCH" ]; then
      rm -rf "$ARCH"
    fi

    mv .git/config config
    rm -rf .git

    git init
    mv config .git/config

    git branch -m master main

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
    git push -f --set-upstream origin main

    cd ..
  fi

  # Delete files from gh release repo
  local gh_token=$(config_get gh_release_token)
  local gh_owner=$(config_get gh_release_owner)
  local gh_repo=$(config_get gh_release_repo)

  if [ "$gh_owner" != "" ] && [ "$gh_repo" != "" ] && [ "$gh_token" != "" ]; then
    local json_output=$(curl \
      -H "Authorization: token $gh_token"  \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/$gh_owner/$gh_repo/releases/tags/$ARCH
    )

    local error=$(printf "%s" "$json_output" | jq -r ".message" 2>/dev/null)

    if [ "$error" != "null" ] && [ "$?" != "0" ]; then
      return
    fi

    # Delete all packages
    printf "%s" "$json_output" | jq -r '.assets | .[] | .id' | \
    while read -r asset_id ; do
      curl \
        -X DELETE \
        -H "Authorization: token $gh_token" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$gh_owner/$gh_repo/releases/assets/$asset_id"
    done
  fi
}

sync_repo(){
  local ARCH=$(uname -m)
  local REPONAME=$(config_get reponame)

  if [ "$(config_get hostname)" != "" ]; then
    if [ ! -e "upload" ]; then
      mkdir upload
    else
      rm -rf upload
      mkdir upload
    fi

    sshfs "$(config_get hostname)" upload
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

  sync_repo_gh_release
}

sync_repo_gh_release(){
  local ARCH=$(uname -m)
  local REPONAME=$(config_get reponame)
  local gh_token=$(config_get gh_release_token)
  local gh_owner=$(config_get gh_release_owner)
  local gh_repo=$(config_get gh_release_repo)

  if [ "$gh_owner" = "" ] || [ "$gh_repo" = "" ] || [ "$gh_token" = "" ]; then
    return
  fi

  echo "Getting release info..."
  json_output=$(curl \
    -H "Authorization: token $gh_token"  \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/$gh_owner/$gh_repo/releases/tags/$ARCH
  )

  local error=$(printf "%s" "$json_output" | jq -r ".message" 2>/dev/null)

  if [ "$error" != "null" ] && [ "$?" != "0" ]; then
    echo "Error: $error"
    return
  elif [ "$error" = "Bad credentials" ] || [ "$error" != "Not Found" ]; then
    if [ "$error" != "null" ]; then
      echo "Error: $error"
      return
    fi
  elif [ "$error" = "Not Found" ]; then
    echo "Creating release..."
    json_output=$(curl \
      -X POST \
      -H "Authorization: token $gh_token" \
      -H "Accept: application/vnd.github.v3+json" \
      https://api.github.com/repos/$gh_owner/$gh_repo/releases \
      -d '{"tag_name":"'$ARCH'"}'
    )

    error=$(printf "%s" "$json_output" | jq -r ".message" 2>/dev/null)

    if [ "$error" != "null" ] && [ "$?" != "0" ]; then
      echo "Error: release could not be created with error:"
      echo "$error"
      return
    fi
  fi

  local upload_url=$(printf "%s" "$json_output" | jq -r .upload_url)
  upload_url=$(echo $upload_url | cut -d"{" -f1)

  local files_uploaded=0
  for file in $(ls $ARCH/*.pkg.* | xargs) ; do
    local file_size=$(stat --format="%s" "$file")
    local file_name=$(basename $file)

    if [ $((file_size/1024/1024)) -gt $((2*1024)) ]; then
      echo "Skiping '$file_name' larger than 2Gb"
      continue
    fi

    local found=$(printf "%s" "$json_output" | jq '.assets | .[] | select(.name=="'$file_name'")')

    if [ "$found" = "" ]; then
      echo "Uploading $file..."
      local upload_json=$(curl \
        -H "Authorization: token $gh_token" \
        -H "Content-Type: $(file -b --mime-type $file)" \
        --data-binary @$file \
        "${upload_url}?name=${file_name}"
      )
      files_uploaded=1
    fi
  done

  # Check if files need to be deleted
  local files_delete=0
  while read -r file ; do
    if [ ! -e "$ARCH/$file" ]; then
      files_delete=1
      break
    fi
  done < <(printf "%s" "$json_output" | jq -r '.assets | .[] | .name')

  if [ $files_uploaded -gt 0 ] || [ $files_delete -gt 0 ]; then
    # Upload new packages db file or update existing one.
    echo "Updating ${REPONAME}.db..."
    local repo_db=$(printf "%s" "$json_output" | jq '.assets | .[] | select(.name=="'${REPONAME}.db'")')
    if [ "$repo_db" != "" ]; then
      local asset_id=$(printf "%s" "$json_output" | \
        jq '.assets | .[] | select(.name=="'${REPONAME}.db'") | .id'
      )

      curl \
        -X DELETE \
        -H "Authorization: token $gh_token" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$gh_owner/$gh_repo/releases/assets/$asset_id"
    fi
    local upload_json=$(curl \
      -H "Authorization: token $gh_token" \
      -H "Content-Type: $(file -b --mime-type ${ARCH}/${REPONAME}.db)" \
      --data-binary @${ARCH}/${REPONAME}.db \
      "${upload_url}?name=${REPONAME}.db"
    )

    # Upload new files db file or update existing one.
    echo "Updating ${REPONAME}.files..."
    local repo_files=$(printf "%s" "$json_output" | jq '.assets | .[] | select(.name=="'${REPONAME}.files'")')
    if [ "$repo_files" != "" ]; then
      local asset_id=$(printf "%s" "$json_output" | \
        jq '.assets | .[] | select(.name=="'${REPONAME}.files'") | .id'
      )

      curl \
        -X DELETE \
        -H "Authorization: token $gh_token" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$gh_owner/$gh_repo/releases/assets/$asset_id"
    fi
    local upload_json=$(curl \
      -H "Authorization: token $gh_token" \
      -H "Content-Type: $(file -b --mime-type ${ARCH}/${REPONAME}.files)" \
      --data-binary @${ARCH}/${REPONAME}.files \
      "${upload_url}?name=${REPONAME}.files"
    )

    # Re-upload packages.json
    echo "Updating packages.json..."
    local repo_files=$(printf "%s" "$json_output" | jq '.assets | .[] | select(.name=="'packages.json'")')
    if [ "$repo_files" != "" ]; then
      local asset_id=$(printf "%s" "$json_output" | \
        jq '.assets | .[] | select(.name=="'packages.json'") | .id'
      )

      curl \
        -X DELETE \
        -H "Authorization: token $gh_token" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/$gh_owner/$gh_repo/releases/assets/$asset_id"
    fi
    local upload_json=$(curl \
      -H "Authorization: token $gh_token" \
      -H "Content-Type: $(file -b --mime-type ${ARCH}/packages.json)" \
      --data-binary @${ARCH}/packages.json \
      "${upload_url}?name=packages.json"
    )

    # Delete old package versions
    printf "%s" "$json_output" | jq -r '.assets | .[] | .name' | \
    while read -r file ; do
      if [ ! -e "$ARCH/$file" ]; then
        local asset_id=$(printf "%s" "$json_output" | \
          jq '.assets | .[] | select(.name=="'${file}'") | .id'
        )

        echo "Deleting ${file}..."

        curl \
          -X DELETE \
          -H "Authorization: token $gh_token" \
          -H "Accept: application/vnd.github.v3+json" \
          "https://api.github.com/repos/$gh_owner/$gh_repo/releases/assets/$asset_id"
      fi
    done
  fi
}

add_packages(){
  local ARCH=$(uname -m)
  local REPONAME=$(config_get reponame)

  rm "$ARCH"/"$REPONAME".*

  repo-add --new --prevent-downgrade "$ARCH"/"$REPONAME".db.tar.gz \
    $(ls "$ARCH"/* | grep -v $REPONAME.db | grep -v $REPONAME.files | grep -v packages.json)

  rm "$ARCH"/"$REPONAME".db
  mv "$ARCH"/"$REPONAME".db.tar.gz "$ARCH"/"$REPONAME".db

  rm "$ARCH"/"$REPONAME".files
  mv "$ARCH"/"$REPONAME".files.tar.gz "$ARCH"/"$REPONAME".files
}

repo_usage(){
  echo "# Example usage of this repository on /etc/pacman.conf"

  if [ "$(config_get reponame)" != "" ]; then
    echo "[$(config_get reponame)]"
  else
    echo "[reponame]"
  fi

  echo "SigLevel = Optional TrustedOnly"

  if [ "$(config_get hostname)" != "" ]; then
    if [ "$(config_get webserver)" != "" ]; then
      echo "Server = $(config_get webserver)/\$repo/\$arch"
    else
      echo "Server = http://localhost/\$repo/\$arch"
    fi
  fi

  if [ -e "git-repo" ]; then
    local git_repo=$(config_get git_repo)
    local owner=$(echo "$git_repo" \
      | sed -n "s/.*:\(.*\)\/.*/\1/p"
    )
    local repo=$(echo "$git_repo" \
      | sed -n "s/.*:.*\/\(.*\)/\1/p"
    )
    echo "Server = https://raw.githubusercontent.com/$owner/$repo/main/\$arch"
  fi

  local gh_token=$(config_get gh_release_token)
  local gh_owner=$(config_get gh_release_owner)
  local gh_repo=$(config_get gh_release_repo)

  if [ "$gh_owner" != "" ] && [ "$gh_repo" != "" ] && [ "$gh_token" != "" ]; then
    echo "Server = https://github.com/$gh_owner/$gh_repo/releases/download/\$arch"
  fi
}

pkgbuild_get_description(){
  local package_info=""

  if [ ! -e "packages/$1/PKGBUILD" ]; then
    echo "$1"
    return 1
  fi

  cd packages/"$1"

  if [ ! -e .SRCINFO ]; then
    # Get package info from cache
    package_info=$(cat "$CURRENT_DIR"/cache/"$1")
  else
    # Use already provided .SRCINFO which is faster
    package_info=$(cat .SRCINFO)
  fi

  cd ../../

  local defaultdesc=$(echo "$package_info" \
    | grep "pkgdesc = " | head -n1 | cut -d"=" -f2 | sed "s/^ *//"
  )

  local action="pkgname"

  local pkgname=""
  local pkgdesc=""

  while read line; do
    local name=$(echo $line | cut -d"=" -f1 | sed "s/ //g")
    local value=$(echo $line | cut -d"=" -f2 | sed "s/^ *//")

    if [ "$action" = "pkgdesc" -a "$name" = "pkgdesc" ]; then
      echo "$value"
      return
    elif [ "$action" = "pkgname" -a "$name" = "pkgname" ]; then
      if [ "$value" = "$2" ]; then
        action="pkgdesc"
      fi
    fi
  done < <(echo "$package_info")

  echo "$defaultdesc"
}

pkgbuild_get_packages(){
  local package_info=""

  if [ "$2" = "" ]; then
    if [ ! -e "packages/$1/PKGBUILD" ]; then
      echo "$1"
      return 1
    fi

    cd packages/"$1"

    if [ ! -e .SRCINFO ]; then
      # Get package info from cache
      package_info=$(cat "$CURRENT_DIR"/cache/"$1")
    else
      # Use already provided .SRCINFO which is faster
      package_info=$(cat .SRCINFO)
    fi

    cd ../../
  else
    package_info=$(cat "$2")
  fi

  local packages=()
  local action="name"

  local pkgname=""
  local pkgver=""
  local pkgrel=""
  local epoch=""
  local subpackages=()
  local mainpkg=""

  while read line; do
    local name=$(echo $line | cut -d"=" -f1 | sed "s/ //g")
    local value=$(echo $line | cut -d"=" -f2 | sed "s/ //g")

    if [ "$action" = "name" -a "$name" = "pkgbase" ]; then
      if [[ ! " ${packages[@]} " =~ " $value " ]]; then
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
          subpackages+=("$value-${epoch}:$pkgver-$pkgrel")
        else
          subpackages+=("$value-$pkgver-$pkgrel")
        fi
      fi
    fi

    if [ "$action" = "done" -a "$pkgname" != "" ]; then
      if [ "$epoch" != "" ]; then
        mainpkg="$pkgname-${epoch}:$pkgver-$pkgrel"
      else
        mainpkg="$pkgname-$pkgver-$pkgrel"
      fi
      action="pkgname"
    fi
  done < <(echo "$package_info")

  # If subpackages found only return those.
  if [ ${#subpackages[@]} -gt 0 ]; then
    local pkg=""
    for pkg in "${subpackages[@]}"; do
      echo "$pkg"
    done
  else
    echo "$mainpkg"
  fi
}

pkgbuild_get_version(){
  local package_info=""

  if [ "$2" = "" ]; then
    if [ ! -e "packages/$1/PKGBUILD" ]; then
      echo "$1"
      return 1
    fi

    cd packages/"$1"

    if [ ! -e .SRCINFO ]; then
      # Get package info from cache
      package_info=$(cat "$CURRENT_DIR"/cache/"$1")
    else
      # Use already provided .SRCINFO which is faster
      package_info=$(cat .SRCINFO)
    fi

    cd ../../
  else
    package_info=$(cat "$2")
  fi

  local action="version"

  local pkgver=""
  local pkgrel=""
  local epoch=""

  while read line; do
    local name=$(echo $line | cut -d"=" -f1 | sed "s/ //g")
    local value=$(echo $line | cut -d"=" -f2 | sed "s/ //g")

    if [ "$action" = "version" -a "$name" = "pkgver" ]; then
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
    fi

    if [ "$action" = "done" ]; then
      if [ "$epoch" != "" ]; then
        echo "${epoch}:$pkgver-$pkgrel"
      else
        echo "$pkgver-$pkgrel"
      fi
      return 0
    fi
  done < <(echo "$package_info")

  return 1
}

pkgbuild_build_if_needed(){
  local ARCH=$(uname -m)

  # Remove package directory if PKGBUILD doesn't exists
  if [ ! -e "packages/$1/PKGBUILD" ]; then
    echo "Package not found."
    return 3
  fi

  # We replace package versions of type:
  # {epoch}:{version} to {epoch}.{version} to prevent issues
  # with some hosters not supporting the : character.
  local pkg=$(echo $2 | sed "s/:/\./g")

  found=$(ls "$ARCH" | grep -F "$pkg-$ARCH.pkg.tar.")
  if [ "$found" = "" ]; then
    echo "Building $pkg..."
    cd packages/"$1"

    pkgbuild_build_dependencies $1 > build.log 2>&1 3>&1

    makepkg -s --rmdeps --noprogressbar --noconfirm --clean --cleanbuild >> build.log 2>&1 3>&1
    make_status=$?
    if [ $make_status -eq 0 ]; then
      if [ -e "current_packages" ]; then
        local package=""
        for package in $(cat current_packages); do
          rm -vf ../../"$ARCH"/"$package"*".pkg.tar."*
        done
      else
        rm -vf ../../"$ARCH"/"$1"*".pkg.tar."*
      fi

      local file=""
      for file in $(ls *.pkg.tar.*); do
        if echo $file | grep ":" > /dev/null ; then
          local file_new=$(echo $file | sed "s/:/\./g")
          mv "$file" "$file_new"
        fi
      done

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
    echo "$pkg already built..."
    return 2
  fi
}

pkgbuild_build(){
  echo  "Builiding packages .SRCINFO cache... "
  pkgbuild_srcinfo_cache

  echo "Starting build process..."

  local built=0
  local names="$(pkgbuild_get_packages "$1")"
  local name=""
  for name in $(echo $names | xargs); do
    pkgbuild_build_if_needed "$1" "$name"
    if [ $? -eq 1 ]; then
      built=1
    fi
    break
  done
  if [ $built -gt 0 ]; then
    local names_no_colon=$(echo $names | sed "s/:/\./g")
    echo $names_no_colon > packages/$1/current_packages
  fi

  echo "Removing .SRCINFO cache dir..."
  rm -rf cache
}

pkgbuild_build_dependencies(){
  local ARCH=$(uname -m)
  local previous_dir=$(pwd)

  cd $CURRENT_DIR

  if [ -e "packages/$1/PKGBUILD" ]; then
    local pkgbuild=""
    if [ -e "packages/$1/.SRCINFO" ]; then
      pkgbuild=$(cat "packages/$1/.SRCINFO")
    else
      cd "packages/$1"
      pkgbuild=$(makepkg --printsrcinfo)
      cd ../..
    fi

    local dependencies=()

    while read -r line ; do
      dependencies+=($(echo $line | cut -d"=" -f2 | sed "s/ //g"))
    done < <(echo "$pkgbuild" | grep -E "(\s+makedepends = )|(\s+depends = )")

    local dependency=""
    for dependency in "${dependencies[@]}" ; do
      cd cache
      local package=$(grep -RE 'pkgname = '"$dependency"'$' | cut -d":" -f1)
      cd ..

      if [ "$package" != "" ] && [ "$package" != "$1" ] ; then
        echo "Checking if dependecy '$dependency' needs building and installing."
        local package_version=$(pkgbuild_get_version $package cache/$package \
          | head -n1
        )

        echo "  Package version $package_version"

        local installed_version=$(pacman -Qi "$dependency" 2>/dev/null \
          | grep "Version" \
          | cut -d":" -f2 | sed "s/ //"
        )

        # install package if not already installed
        if [ "$installed_version" = "" ] || [ "$installed_version" != "$package_version" ]; then
          echo "  Checking if build needed and build"
          pkgbuild_build_if_needed "$package" "$package-$package_version"

          echo "  Checking if install needed and install"

          local version_no_colon=$(echo "$package_version" | sed "s/:/\./g")

          sudo pacman -U --needed --noconfirm "$ARCH/$dependency-$version_no_colon"*
        else
          echo "  Installed version $installed_version"
        fi
      fi
    done
  fi

  cd "$previous_dir"

  return 0
}

pkgbuild_clean_removed(){
  echo "Performing repository cleaning..."
  local package=""
  for package in $(ls packages) ; do
    if [ ! -d "packages/$package" ]; then
      continue
    fi

    if [ ! -e "packages/$package/PKGBUILD" ]; then
      if [ -e "packages/$package/current_packages" ]; then
        local entry=""
        for entry in $(cat packages/$package/current_packages); do
          rm -vf "$ARCH"/"$entry"*".pkg.tar."*
        done
      else
        rm -vf "$ARCH"/"$package"*".pkg.tar."*
      fi
      rm -rf "packages/$package"
      echo "  Package '$package' removed from repository."
    fi
  done
}

pkgbuild_srcinfo_cache(){
  if [ ! -e "cache" ]; then
    mkdir cache
  else
    rm -rf cache
    mkdir cache
  fi

  local packages=()
  if [ "$1" = "" ]; then
    if [ -e "skip" ]; then
      packages=(
        $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2 | grep -v -f skip)
      )
    else
      packages=(
        $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2)
      )
    fi
  else
    packages=($@)
  fi

  for entry in "${packages[@]}"; do
    if [ -d "packages/$entry" ] && [ -e "packages/$entry/PKGBUILD" ]; then
      if [ -e "packages/$entry/.SRCINFO" ]; then
        cp "packages/$entry/.SRCINFO" cache/$entry
      else
        echo "  Building .SRCINFO for '$entry'..."
        cd packages/$entry

        # Update pkgver if possible (since this package may be a VCS)
        makepkg -s --noconfirm --nobuild --clean > /dev/null 2>&1 3>&1

        if [ "$?" != "0" ]; then
          echo "    Failed"
          exit 1
        else
          makepkg --printsrcinfo > "$CURRENT_DIR/cache/$entry"
        fi

        rm -rf src pkg

        cd ../../
      fi
    fi
  done
}

build_packages_json(){
  local output="{\n"
  output="$output  packages: [\n"

  local first=1

  for package in $(ls cache); do
    local pkgver=$(pkgbuild_get_version "$package")
    local subpackage=""
    for subpackage in $(pkgbuild_get_packages "$package"); do
      local name=$(echo $subpackage | sed "s|-$pkgver||")
      local pkgdesc=$(pkgbuild_get_description "$package" "$name")
      if [ $first -lt 1 ]; then
        output="$output,\n"
      fi
      output="$output    {\n"
      output="$output"'      name: "'$name'",\n'
      output="$output"'      description: "'$(echo "$pkgdesc" | sed 's|"|\"|g')'",\n'
      output="$output"'      version: "'$pkgver'"\n'
      output="$output    }"
      first=0
    done
  done

  output="$output\n"

  output="$output  ]\n"
  output="$output}"

  echo -e "$output"
}

build_packages(){
  local ARCH=$(uname -m)
  local REPONAME=$(config_get reponame)
  local PACKAGES_BUILT=()

  echo "Started on: $(date)"

  if [ ! -e "$ARCH" ]; then
    mkdir "$ARCH"
  fi

  #
  # Update PKGBUILDs repository
  #
  cd packages
  if ! git checkout master >/dev/null 2>&1 ; then
    if ! git checkout main >/dev/null 2>&1 ; then
      echo "No master or main branch found on the packages repo."
      cd ..
      exit 1
    fi
  fi
  git restore .
  git config pull.rebase false
  git pull
  cd ..

  # Remove packages deleted from git repo
  pkgbuild_clean_removed

  #
  # Make a list of packages to build
  #
  local temp_packages=()
  if [ -e "skip" ]; then
    temp_packages=(
      $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2 | grep -v -f skip)
    )
  else
    temp_packages=(
      $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2)
    )
  fi

  # Array to store the packages to build
  local packages=()

  # Check if commit of last build is available.
  local last_commit=$(config_get last_commit)

  if [ "$last_commit" = "" ] || [ ! -e "packages/.git" ] ; then
    # No previous commit stored so try to build all packages.
    packages=(${temp_packages[@]})
  else
    # Previous commit found so build only updated and vcs packages.
    cd packages
    local newest_commit=$(git log -n 1 --format="%H")

    # Store list of packages that changed
    if [ "$last_commit" != "$newest_commit" ]; then
      while read -r line ; do
        local package=$(echo $line | cut -d"/" -f1)
        if [ -e "$package" ]; then
          packages+=($(echo $line | cut -d"/" -f1))
        fi
      done < <(git diff --name-only $last_commit $newest_commit | grep "/PKGBUILD")
    fi

    # Now add packages without .SRCINFO, they should be vcs packages
    local package=""
    for package in "${temp_packages[@]}" ; do
      if [ ! -e "$package/.SRCINFO" ]; then
        packages+=($package)
      fi
    done
    cd ..
  fi

  # unset temp_packages
  unset temp_packages

  if [ ${#packages[@]} -lt 1 ]; then
    echo "No package needs building."
  else
    sudo pacman -Suy --noconfirm

    if [ "$?" != "0" ]; then
      echo "Error while upgrading system packages."
      exit 1
    fi

    echo  "Builiding packages .SRCINFO cache... "
    pkgbuild_srcinfo_cache

    echo "Starting build process..."

    #
    # Build packages not already built or outdated
    #
    local package=""
    for package in "${packages[@]}"; do
      local built=0
      local names=$(pkgbuild_get_packages "$package")
      local name=""
      for name in $(echo $names | xargs); do
        pkgbuild_build_if_needed "$package" "$name"
        if [ $? -eq 1 ]; then
          PACKAGES_BUILT+=("$package")
          built=1
        fi
        break
      done
      if [ $built -gt 0 ]; then
        local names_no_colon=$(echo $names | sed "s/:/\./g")
        echo $names_no_colon > packages/$package/current_packages
      fi
    done

    #
    # Upload built packages
    #
    if [ ${#PACKAGES_BUILT[@]} -gt 0 ]; then
      echo "Generating packages.json..."
      build_packages_json > "$ARCH/packages.json"

      add_packages
      sync_repo
    fi

    # Save the commit we just built.
    cd packages
    local last_commit="$(git log -n 1 --format='%H')"
    cd ..
    config_write last_commit "$last_commit"

    # remove srcinfo cache dir
    echo "Removing .SRCINFO cache dir..."
    rm -rf cache
  fi

  echo "Ended on: $(date)"
}

# This function was written only to run it on older repo with old
# build script that didn't had support for current_packages
generate_current_packages(){
  local ARCH=$(uname -m)
  local REPONAME=$(config_get reponame)
  local PACKAGES_BUILT=()

  if [ ! -e "$ARCH" ]; then
    echo "No packages are currently built no need to run this."
    return
  fi

  echo "Generating current_packages file..."

  #
  # Make a list of packages to build
  #
  local packages=()
  packages=(
    $(find packages -maxdepth 1 -type d -not -name ".git" | tail -n +2 | cut -d"/" -f2)
  )

  #
  # Generate current_packages file for packages not containing one.
  #
  local package=""
  for package in "${packages[@]}"; do
    local built=0
    local names=$(pkgbuild_get_packages "$package")
    if [ ! -e packages/$package/current_packages ]; then
      echo $names
      echo $names > packages/$package/current_packages
    fi
  done
}

#######################################################################
# Main execution entry point
#######################################################################
if [ ! -e "packages" ]; then
  echo "You must run the setup to initialize the PKGBUILDs repository."
  echo -n "Do you want to run the setup now? [y/n]: "
  read run_setup
  if [ "$run_setup" = "y" ]; then
    setup_repo
    echo "Setup complete!"
    exit 0
  else
    exit 1
  fi
fi

case $1 in
  'config-get' )
    shift
    config_get $@
    exit
    ;;
  'config-set' )
    shift
    config_write $@
    exit
    ;;
  'setup' )
    setup_repo
    exit
    ;;
  'setupgh' )
    setup_gh_repo
    exit
    ;;
  'setupghr' )
    setup_gh_release_repo
    exit
    ;;
  'setupweb' )
    setup_webserver_repo
    exit
    ;;
  'clean' )
    clean_repo
    exit
    ;;
  'gencurpkg' )
    # only used for old repo or troubleshooting
    generate_current_packages
    exit
    ;;
  'addpkgs' )
    add_packages
    sync_repo
    exit
    ;;
  'pkgnames' )
    shift
    pkgbuild_srcinfo_cache $@ > /dev/null 2>&1 3>&1
    pkgbuild_get_packages $@
    rm -rf cache
    exit
    ;;
  'pkgver' )
    shift
    pkgbuild_srcinfo_cache $@ > /dev/null 2>&1 3>&1
    pkgbuild_get_version $@
    rm -rf cache
    exit
    ;;
  'pkgjson' )
    shift
    pkgbuild_srcinfo_cache > /dev/null 2>&1 3>&1
    build_packages_json
    rm -rf cache
    exit
    ;;
  'repodef' )
    repo_usage
    exit
    ;;
  'build' )
    build_packages
    exit
    ;;
  'buildpkg' )
    shift
    pkgbuild_build $@
    exit
    ;;
  * )
    script_name=$(basename $0)
    g="\e[32m" # green
    d="\e[0m"  # default
    echo "Helper script to maintain an archlinux repo."
    echo ""
    echo "Usage: $script_name [COMMAND] [<parameter>]"
    echo ""
    echo "Available Commands:"
    echo ""
    echo -e "  ${g}setup${d}       Initialize the system for building."
    echo -e "  ${g}setupgh${d}     (Re)configure a github repository mirror"
    echo -e "  ${g}setupghr${d}    (Re)configure a github repository for releases as mirror"
    echo -e "  ${g}setupweb${d}    (Re)configure a webserver as mirror"
    echo -e "  ${g}config-get${d}  Gets the value of an option on the config.ini."
    echo -e "              Params: <option-name>"
    echo -e "  ${g}config-set${d}  Set the value of an option on the config.ini."
    echo -e "              Params: <option-name> <option-value>"
    echo -e "  ${g}clean${d}       Remove all packages locally and remotely."
    echo -e "  ${g}build${d}       Build outdated or missing packages and sync to server."
    echo -e "  ${g}buildpkg${d}    Build a single package without syncing."
    echo -e "              Params: <package-name>"
    echo -e "  ${g}addpkgs${d}     Generate repo databases and upload sync to server."
    echo -e "  ${g}pkgnames${d}    Get a package names list."
    echo -e "              Params: <package-name>"
    echo -e "  ${g}pkgver${d}      Get package latest version."
    echo -e "              Params: <package-name>"
    echo -e "  ${g}pkgjson${d}     Generate json information of all packages."
    echo -e "  ${g}repodef${d}     View pacman.conf repo sample definition."
    echo -e "  ${g}help${d}        Print this help."
    exit
    ;;
esac
