<?xml version="1.0" encoding="utf-8"?>
<!--
  ha-mail :: /var/www/autoconfig/autodiscover/autodiscover.xml
  Outlook-style autodiscover.

  Served statically. Outlook POSTs an XML request body containing the user's
  address; a static POX response is a valid answer and keeps an
  unauthenticated endpoint from executing any code. The trade-off is that the
  response cannot echo the requested address, which Outlook tolerates.
-->
<Autodiscover xmlns="http://schemas.microsoft.com/exchange/autodiscover/responseschema/2006">
  <Response xmlns="http://schemas.microsoft.com/exchange/autodiscover/outlook/responseschema/2006a">
    <Account>
      <AccountType>email</AccountType>
      <Action>settings</Action>

      <Protocol>
        <Type>IMAP</Type>
        <Server>${MAIL_HOST}</Server>
        <Port>993</Port>
        <SSL>on</SSL>
        <Encryption>SSL</Encryption>
        <SPA>off</SPA>
        <AuthRequired>on</AuthRequired>
        <DomainRequired>off</DomainRequired>
      </Protocol>

      <Protocol>
        <Type>SMTP</Type>
        <Server>${MAIL_HOST}</Server>
        <Port>465</Port>
        <SSL>on</SSL>
        <Encryption>SSL</Encryption>
        <SPA>off</SPA>
        <AuthRequired>on</AuthRequired>
        <UsePOPAuth>off</UsePOPAuth>
        <SMTPLast>off</SMTPLast>
      </Protocol>
    </Account>
  </Response>
</Autodiscover>
