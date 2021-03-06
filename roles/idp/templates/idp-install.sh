#!/bin/bash -e
#
# idp-install.sh - custom installer for the Shibboleth IdP 3
#
# Copyright (c) 2015 SWITCH
# This has been edited by DS but credit still goes to the original creator
# Edited by Derrick Ssemanda on 17/01/2020

set -e

trap 'echo "
ERROR: command execution failed, see above. Aborting."' ERR

INSTALLDIR=/opt/shibboleth-idp

if [ -d $INSTALLDIR ]; then
  echo "$INSTALLDIR already exists. Aborting."
  exit 1
fi

if [ $(id -u) -ne 0 ]; then
  echo "Must be run with root privileges. Aborting."
  exit 1
fi

if [ $# -ne 1 ]; then
  echo "Mandatory argument (IdP distribution directory) is missing. Aborting."
  exit 1
fi

if [ ! -x $1/bin/install.sh ]; then
  echo "$1/bin/install.sh not found (incorrect IdP distribution directory?). Aborting."
  exit 1
fi

export JAVA_HOME=${JAVA_HOME:-$(ls -d /usr/lib/jvm/java-1.7.0-openjdk-* 2>/dev/null | tail -1)/jre}
if [ -z "$JAVA_HOME" ]; then
  echo "\$JAVA_HOME not set, and no suitable JRE version found under /usr/lib/jvm"
  exit 1
fi

cd $1

while [ "$ANS" != "yes" ]; do
  DFLT=test.renu.ac.ug
  read -p "Please enter the name of your home organization [$DFLT]: " SCOPE
  SCOPE=${SCOPE:-$DFLT}

  DFLT=idp.$SCOPE
  read -p "Please specify the service name for your IdP [$DFLT]: " SVCNAME
  SVCNAME=${SVCNAME:-$DFLT}
  echo

  cat <<-EOM
	Proceed with the installation using the following parameters?

	Service name:             $SVCNAME
	Home organization name:   $SCOPE
	Installation directory:   $INSTALLDIR

	EOM

  read -p "Enter 'yes' to continue: " ANS
  echo
done

# generate a password for client-side encryption
echo "idp.sealer.password = $(openssl rand -base64 12)" >credentials.properties
chmod 0600 credentials.properties

# preconfigure settings for a typical SWITCHaai deployment
cat >temp.properties <<EOF
idp.additionalProperties= /conf/ldap.properties, /conf/saml-nameid.properties, /conf/services.properties, /conf/credentials.properties
idp.sealer.storePassword= %{idp.sealer.password}
idp.sealer.keyPassword= %{idp.sealer.password}
idp.signing.key= %{idp.home}/credentials/idp.key
idp.signing.cert= %{idp.home}/credentials/idp.crt
idp.encryption.key= %{idp.home}/credentials/idp.key
idp.encryption.cert= %{idp.home}/credentials/idp.crt
idp.entityID= https://$SVCNAME/idp/shibboleth
idp.scope= $SCOPE
idp.consent.StorageService= shibboleth.JPAStorageService
idp.consent.userStorageKey= shibboleth.consent.AttributeConsentStorageKey
idp.consent.userStorageKeyAttribute= %{idp.persistentId.sourceAttribute}
idp.consent.allowGlobal= false
idp.consent.compareValues= true
idp.consent.maxStoredRecords= -1
idp.ui.fallbackLanguages= en,fr
idp.entityID.metadataFile=
EOF

# run the installer
bin/install.sh \
-Didp.relying.party.present= \
-Didp.src.dir=. \
-Didp.target.dir=$INSTALLDIR \
-Didp.merge.properties=temp.properties \
-Didp.sealer.password=$(cut -d " " -f3 <credentials.properties) \
-Didp.keystore.password= \
-Didp.conf.filemode=644 \
-Didp.keysize=2048  \
-Didp.host.name=$SVCNAME \
-Didp.scope=$SCOPE

mv credentials.properties $INSTALLDIR/conf

echo -e "\nCreating self-signed certificate..."
$INSTALLDIR/bin/keygen.sh --lifetime 10 \
--certfile $INSTALLDIR/credentials/idp.crt \
--keyfile $INSTALLDIR/credentials/idp.key \
--hostname $SVCNAME \
--uriAltName https://$SVCNAME/idp/shibboleth
echo ...done
chmod 600 $INSTALLDIR/credentials/idp.key

# adapt owner of key file and directories
getent passwd tomcat8 >/dev/null && TCUSER=tomcat8 || TCUSER=tomcat
chown $TCUSER $INSTALLDIR/credentials/{idp.key,sealer.*}
chown $TCUSER $INSTALLDIR/{metadata,logs}
chown $TCUSER $INSTALLDIR/conf/credentials.properties

# create PostgreSQL password, and copy JDBC drivers
if which psql >/dev/null; then
  PSQLPW=$(openssl rand -base64 12)
  echo "psql.password = $PSQLPW" >>$INSTALLDIR/conf/credentials.properties
  echo "ALTER ROLE shibboleth PASSWORD '$PSQLPW'" | su - postgres -c psql >/dev/null

  [ -s /usr/share/java/postgresql-jdbc.jar ] && PSQLJDBC=/usr/share/java/postgresql-jdbc.jar
  [ -s /usr/share/java/postgresql-jdbc4.jar ] && PSQLJDBC=/usr/share/java/postgresql-jdbc4.jar
  [ -n "$PSQLJDBC" ] && ln -s $PSQLJDBC $INSTALLDIR/edit-webapp/WEB-INF/lib
fi
