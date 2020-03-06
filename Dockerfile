#-------------------------------------------------------------------------------------------------------------
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License. See https://go.microsoft.com/fwlink/?linkid=2090316 for license information.
#-------------------------------------------------------------------------------------------------------------
FROM buildpack-deps:stretch@sha256:d095aae2ecefdc786823e02b2cb0abc62b432202a49abd716c12cce37aee702b as builddeps
FROM mcr.microsoft.com/oryx/build:20200114.13 as kitchensink

ARG BASH_PROMPT="PS1='\[\e]0;\u: \w\a\]\[\033[01;32m\]\u\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '"
ARG FISH_PROMPT="function fish_prompt\n    set_color green\n    echo -n (whoami)\n    set_color normal\n    echo -n \":\"\n    set_color blue\n    echo -n (pwd)\n    set_color normal\n    echo -n \"> \"\nend\n"
ARG ZSH_PROMPT="autoload -Uz promptinit\npromptinit\nprompt adam2"

# Define extra paths:
# Language executables provided by Oryx -  see https://github.com/microsoft/Oryx/blob/master/images/build/slim.Dockerfile#L223
ARG EXTRA_PATHS="/opt/oryx:/opt/nodejs/lts/bin:/opt/python/latest/bin:/opt/yarn/stable/bin"
ARG EXTRA_PATHS_OVERRIDES="~/.dotnet"
# ~/.local/bin - For 'pip install --user'
# ~/.npm-global/bin - For npm global bin directory in user directory
ARG USER_EXTRA_PATHS="${EXTRA_PATHS}:~/.local/bin:~/.npm-global/bin"

ARG NVS_HOME="/home/vsonline/.nvs"

ARG DeveloperBuild

# Default to bash shell (other shells available at /usr/bin/fish and /usr/bin/zsh)
ENV SHELL=/bin/bash

ENV ORYX_ENV_TYPE=vsonline-present

# Copy back python into the Oryx image from builddeps.
COPY --from=builddeps /usr/bin/py* /usr/bin/

# Add script to fix .NET Core pathing
ADD symlinkDotNetCore.sh /tmp/vsonline/symlinkDotNetCore.sh

 # Install packages, setup vsonline user
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -yq \
    && apt-get -yq install --no-install-recommends apt-utils dialog 2>&1 \
    && apt-get install -yq \
        default-jdk \
        vim \
        sudo \
        xtail \
        fish \
        zsh \
        curl \
        gnupg \
        apt-transport-https \
        lsb-release \
        software-properties-common \
        unzip \
    #
    # Optionally install debugger for development of VSO
    && if [ -z $DeveloperBuild ]; then \
        echo "not including debugger" ; \
    else \
        curl -sSL https://aka.ms/getvsdbgsh | bash /dev/stdin -v latest -l /vsdbg ; \
    fi \
    #
    # Install Live Share dependencies
    && curl -sSL -o vsls-linux-prereq-script.sh https://aka.ms/vsls-linux-prereq-script \
    && /bin/bash vsls-linux-prereq-script.sh true false false \
    && rm vsls-linux-prereq-script.sh \
    #
    # Install Git LFS
    && curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash \
    && apt-get install -yq git-lfs \
    && git lfs install \
    #
    # Install PowerShell
    && curl -s https://packages.microsoft.com/keys/microsoft.asc | (OUT=$(apt-key add - 2>&1) || echo $OUT) \
    && echo "deb [arch=amd64] https://packages.microsoft.com/repos/microsoft-debian-stretch-prod stretch main" > /etc/apt/sources.list.d/microsoft.list \
    && apt-get update -yq \
    && apt-get install -yq powershell \
    #
    # Install Azure CLI
    && echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/azure-cli.list \
    && curl -sL https://packages.microsoft.com/keys/microsoft.asc | (OUT=$(apt-key add - 2>&1) || echo $OUT) \
    && apt-get update \
    && apt-get install -y azure-cli \
    #
    # Setup vsonline user
    && { echo && echo "PATH=${EXTRA_PATHS_OVERRIDES}:\$PATH:${USER_EXTRA_PATHS}" ; } | tee -a /etc/bash.bashrc >> /etc/skel/.bashrc \
    && { echo && echo $BASH_PROMPT ; } | tee -a /etc/bash.bashrc >> /etc/skel/.bashrc \
    && printf "$FISH_PROMPT" >> /etc/fish/conf.d/fish_prompt.fish \
    && { echo && echo $ZSH_PROMPT ; } | tee -a /etc/zsh/zshrc >> /etc/skel/.zshrc \
    && useradd --create-home --shell /bin/bash vsonline \
    && mkdir -p /etc/sudoers.d \
    && echo "vsonline ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/nopasswd \
    && echo "Defaults secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin:${EXTRA_PATHS}\"" >> /etc/sudoers.d/securepath \
    && sudo -u vsonline mkdir /home/vsonline/.vsonline \
    #
    # Setup .NET Core
    # Hack to get dotnet core sdks in the right place - Oryx images do not put dotnet on the path because it will break AppService.
    # The following script will put the dotnet's at /home/vsonline/.dotnet folder where dotnet will look by default.
    && mv /tmp/vsonline/symlinkDotNetCore.sh /home/vsonline/symlinkDotNetCore.sh \
    && sudo -u vsonline /bin/bash /home/vsonline/symlinkDotNetCore.sh 2>&1 \
    && rm /home/vsonline/symlinkDotNetCore.sh \
    #
    # Setup Node.js
    && sudo -u vsonline npm config set prefix /home/vsonline/.npm-global \
    && npm config -g set prefix /home/vsonline/.npm-global \
    # Install nvm (popular Node.js version-management tool)
    && sudo -u vsonline curl -s -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.35.1/install.sh | sudo -u vsonline bash 2>&1 \
    && rm -rf /home/vsonline/.nvm/.git \
    # Install nvs (alternate cross-platform Node.js version-management tool)
    && sudo -u vsonline git clone -b v1.5.4 -c advice.detachedHead=false --depth 1 https://github.com/jasongin/nvs ${NVS_HOME} 2>&1 \
    && sudo -u vsonline /bin/bash ${NVS_HOME}/nvs.sh install \
    && rm -rf ${NVS_HOME}/.git \
    # Clear the nvs cache and link to an existing node binary to reduce the size of the image.
    && rm ${NVS_HOME}/cache/* \
    && sudo -u vsonline ln -s /opt/nodejs/10.17.0/bin/node ${NVS_HOME}/cache/node \
    && sed -i "s/node\/[0-9.]\+/node\/10.17.0/" ${NVS_HOME}/defaults.json \
    #
    # Remove 'imagemagick imagemagick-6-common' due to http://cve.mitre.org/cgi-bin/cvename.cgi?name=CVE-2019-10131
    && apt-get purge -y imagemagick imagemagick-6-common \
    #
    # Clean up
    && apt-get autoremove -y \
    && apt-get clean -y
ENV DEBIAN_FRONTEND=dialog

USER vsonline