#!/usr/bin/env zsh

source $DOTFILES/plugins/nvm.plugin.zsh

nvm install node --latest-npm
nvm use node

nvm upgrade

if ! (( $+commands[yarn] ))
then
  npm install -g yarn
  yarn config set prefix /usr/local/
  yarn global add npm webpack yo jest mocha
else
  npm install npm@latest -g
  npm -g update yarn
  yarn global upgrade --latest
  npm -g update
fi



