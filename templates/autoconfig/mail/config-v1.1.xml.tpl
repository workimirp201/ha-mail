<?xml version="1.0" encoding="UTF-8"?>
<!--
  ha-mail :: /var/www/autoconfig/mail/config-v1.1.xml
  Thunderbird-style autoconfiguration.

  Every hostname advertised here (${MAIL_HOST}) is a DUAL-A record pointing at
  both ${NODE_A_IP} and ${NODE_B_IP}. A client provisioned from this file
  therefore inherits node failover automatically: if one address refuses the
  connection, the OS resolver hands it the other on the next attempt. No
  client-side configuration is aware that two servers exist.
-->
<clientConfig version="1.1">
  <emailProvider id="${DOMAIN}">
    <domain>${DOMAIN}</domain>
    <displayName>${DOMAIN} Mail</displayName>
    <displayShortName>${DOMAIN}</displayShortName>

    <incomingServer type="imap">
      <hostname>${MAIL_HOST}</hostname>
      <port>993</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>

    <incomingServer type="imap">
      <hostname>${MAIL_HOST}</hostname>
      <port>143</port>
      <socketType>STARTTLS</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>

    <outgoingServer type="smtp">
      <hostname>${MAIL_HOST}</hostname>
      <port>465</port>
      <socketType>SSL</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
      <addThisServer>true</addThisServer>
      <useGlobalPreferredServer>false</useGlobalPreferredServer>
    </outgoingServer>

    <outgoingServer type="smtp">
      <hostname>${MAIL_HOST}</hostname>
      <port>587</port>
      <socketType>STARTTLS</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>

    <documentation url="https://${WEBMAIL_HOST}/">
      <descr lang="en">Webmail access</descr>
    </documentation>
  </emailProvider>

  <webMail>
    <loginPage url="https://${WEBMAIL_HOST}/"/>
  </webMail>
</clientConfig>
