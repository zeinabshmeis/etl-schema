#!/bin/bash
# Creates the complete set of public views for a given version.
# Also creates internal views that the public views are built on.
# This should generally be run from a travis deployment, and the
# arguments should be derived from the deployment tag.
# The following legacySQL views are created in the public dataset:
#    ndt_all​ - all (lightly filtered) tests, excluding EB,
#              blacklisted, short and very long tests.
#    Separate views for download and upload NDT tests:
# ​​​     ndt_downloads
#      ndt_uploads
#
# Notes:
# 1. These are the public facing standard views.
# 2. All views filter out EB test results and all views filter out tests where the blacklist_flags field is NULL.
# 3. -f doesn't work on view creation, so we remove existing view first.
# 4. dot (.) cannot be used within a table name, so SemVer is expressed with _.
#
# bq mk --view validates the view query, and fails if the query isn't valid.
# This means that each view must be created before being used in other
# view definitions.

set -u
###########################################################################
#                            Bash Parameters                              #
###########################################################################

USAGE="$0 <project> <public-dataset> <internal-dataset> <alias>"
PROJECT=${1:?Please provide the google cloud project: $USAGE}
PUBLIC=${PROJECT}:${2:?Please specify the public dataset: $USAGE}
INTERNAL=${PROJECT}:${3:?Please specify the internal dataset: $USAGE}
ALIAS=${PROJECT}:${4:?Please specify the alias dataset \{alpha|stable|none\}: $USAGE}

# TODO - check that public and internal aren't swapped?
# TODO - check that project is valid?


###########################################################################
#                       Functions and Variables                           #
###########################################################################

# Note: SQL param may use "" and ``, but should NOT use ''
# This function expects the actual query string in parameter 4
# The SQL string will have any occurance of $STANDARD_SUB replaced
# with the dataset parameter.
# Parameters
#  dataset - project:dataset for the view, and for any $DATASET substitutions
#  view - name of view, e.g. ndt_all
#  description - description string for the view
#  sql - optional sql string.  If not provided, it is loaded from $view.sql
create_view() {
  local dataset=$1
  local view=$2_legacysql
  local description="Release tag: $TRAVIS_TAG     Commit: $TRAVIS_COMMIT"$'\n'$3
  local sql=${4:-`cat $2.sql`}

  # Some FROM targets must link to specified dataset.
  # Substitute dataset name for STANDARD_SUB sql vars.
  sql=`echo "$sql" | DATASET=${dataset/:/.} envsubst '$DATASET'`

  echo $dataset.$view
  bq rm --force $dataset.$view
  bq mk \
    --description="${description}" --view="$sql" $dataset.$view

  # TODO - Travis should cat the bigquery.log on non-zero exit status.

  # This fetches the new table description as json.
  if [[ ! -d json ]];then mkdir json; fi
  bq show --format=prettyjson $dataset.$view > json/$dataset.$view.json
}

###########################################################################
#                        The legacySQL views                            #
###########################################################################

# TODO - if running in travis, set -x

# Create datasets, e.g. for new versions.
# These lines may fail if they already exist, so we run them before set -e.
bq mk ${PUBLIC}
bq mk ${INTERNAL}

# Terminate on error.
set -e
# If executing in travis, be verbose.
if [[ -v TRAVIS ]];then set -x; fi

create_view ${INTERNAL} common_etl \
  'ETL table projected into common schema, for union with PLX legacy data.
  This also adds "ndt.iupui." prefix to the connection_spec.hostname field.'

create_view ${INTERNAL} ndt_exhaustive \
  'Combined view of plx legacy fast table, up to May 10, and new ETL table, from May 11, 2017 onward.
  Includes blacklisted and EB tests, which should be removed before analysis.
  Note that at present, data from May 10 to mid September does NOT have geo annotations.'

create_view ${INTERNAL} ndt_all \
  'View across the all NDT data except EB and blacklisted'

create_view ${INTERNAL} ndt_sensible \
  'View across the all NDT data excluding EB, blacklisted,
  bad end state, short or very long duration'

create_view ${INTERNAL} ndt_downloads \
  'All good quality download tests'

create_view ${INTERNAL} ndt_uploads \
  'All good quality upload tests'

##################################################################################
# These are the minor version public views linking into the corresponding internal
# views.
##################################################################################

create_view ${PUBLIC} ndt_all \
  'View across the all NDT data except EB and blacklisted' \
  '#legacySQL
  SELECT * FROM ['${INTERNAL/:/.}'.ndt_all_legacysql]'

create_view ${PUBLIC} ndt_downloads \
  'All good quality download tests' \
  '#legacySQL
  SELECT * FROM ['${INTERNAL/:/.}'.ndt_downloads_legacysql]'

create_view ${PUBLIC} ndt_uploads \
  'All good quality upload tests' \
  '#legacySQL
  SELECT * FROM ['${INTERNAL/:/.}'.ndt_uploads_legacysql]'

#############################################################################
# Redirect stable, alpha, beta
#############################################################################

# If alias parameter is not "none", this will create the corresponding aliases.
# These datasets are assumed to already exist, so script does not try to
# create them.
# If last parameter is "none" then we skip this section.
# TODO - should link alpha and rc when release is linked?

if [ "${ALIAS}" != "${PROJECT}:none" ]; then
  echo "Creating $ALIAS aliases"

  create_view ${ALIAS} ndt_all \
    'View across the all NDT data except EB and blacklisted' \
    '#legacySQL
    SELECT * FROM ['${INTERNAL/:/.}'.ndt_all_legacysql]'

  create_view ${ALIAS} ndt_downloads \
    'All good quality download tests' \
    '#legacySQL
    SELECT * FROM ['${INTERNAL/:/.}'.ndt_downloads_legacysql]'

  create_view ${ALIAS} ndt_uploads \
    'All good quality upload tests' \
    '#legacySQL
    SELECT * FROM ['${INTERNAL/:/.}'.ndt_uploads_legacysql]'
fi
