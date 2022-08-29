#!/usr/bin/env bash

search_dir=${1:?first parameter is the folder where to search for tests}

hasTests () {
  count=`ls -1 $1/*.js 2>/dev/null | wc -l`
  if [ $count != 0 ]
  then
    return 0
  else
    return 1
  fi  
}
hasSetup () {
  count=`ls -1 $1/setup 2>/dev/null | wc -l`
  [ $count != 0 ]
}
runTests () {
  if [[ hasTests $1 ]]
  then
    echo "$1 has tests"
    if [[ hasSetup $1 ]]
    then
      echo "Calling  $1/setup ..."
#      $1/setup
    fi

    for FILE in $1/*.js; do
       echo "Running $FILE"
#       ./node_modules/.bin/mocha $FILE
    done
  fi

  for d in $1/*/ ; do
    echo "Found folder $d"
  done


}

runTests $search_dir
