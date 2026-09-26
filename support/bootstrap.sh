#!/bin/bash

brew update
brew ls --versions swiftlint && brew upgrade swiftlint || brew install swiftlint
brew ls --versions swiftgen && brew upgrade swiftgen || brew install swiftgen
bundle install || sudo gem install fastlane -NV