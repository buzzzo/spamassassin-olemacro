package Mail::SpamAssassin::Plugin::OLEMacro;

use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Util;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use IO::String;

use strict;
use warnings;
use re 'taint';

use vars qw(@ISA);
@ISA = qw(Mail::SpamAssassin::Plugin);

our $VERSION = '0.42';

# https://www.openoffice.org/sc/compdocfileformat.pdf
# http://blog.rootshell.be/2015/01/08/searching-for-microsoft-office-files-containing-macro/
my $marker1 = "\xd0\xcf\x11\xe0";
my $marker2 = "\x00\x41\x74\x74\x72\x69\x62\x75\x74\x00";

# constructor: register the eval rule
sub new {
  my $class = shift;
  my $mailsaobject = shift;

  # some boilerplate...
  $class = ref($class) || $class;
  my $self = $class->SUPER::new($mailsaobject);
  bless ($self, $class);

  $self->set_config($mailsaobject->{conf});

  $self->register_eval_rule("check_olemacro");
  $self->register_eval_rule("check_olemacro_malice");
  $self->register_eval_rule("check_olemacro_renamed");
  $self->register_eval_rule("check_olemacro_encrypted");
  $self->register_eval_rule("check_olemacro_zip_password");

  return $self;
}

sub dbg {
  Mail::SpamAssassin::Plugin::dbg ("OLEMacro: @_");
}

sub set_config {
  my ($self, $conf) = @_;
  my @cmds = ();

  push(@cmds, {
    setting => 'olemacro_num_mime',
    default => 5,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC,
  });

  push(@cmds, {
    setting => 'olemacro_num_zip',
    default => 5,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC,
  });

  push(@cmds, {
    setting => 'olemacro_zip_depth',
    default => 2,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC,
  });

  push(@cmds, {
    setting => 'olemacro_extended_scan',
    default => 0,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_BOOL,
  });

  push(@cmds, {
    setting => 'olemacro_prefer_contentdisposition',
    default => 1,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_BOOL,
  });

  push(@cmds, {
    setting => 'olemacro_max_file',
    default => 512000,
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_NUMERIC,
  });

  # https://blogs.msdn.microsoft.com/vsofficedeveloper/2008/05/08/office-2007-file-format-mime-types-for-http-content-streaming-2/
  # https://technet.microsoft.com/en-us/library/ee309278(office.12).aspx

  push(@cmds, {
    setting => 'olemacro_exts',
    default => '(?:doc|dot|pot|ppa|pps|ppt|sldm|xl|xla|xls|xlt|xslb)$',
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
    code => sub {
      my ($self, $key, $value, $line) = @_;
      unless (defined $value && $value !~ /^$/) {
        return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
      }
      return $Mail::SpamAssassin::Conf::INVALID_VALUE unless $self->{parser}->is_delimited_regexp_valid('TESTING', $value);

      $self->{olemacro_exts} = $value;
      },
    }
  );

  push(@cmds, {
    setting => 'olemacro_macro_exts',
    default => '(?:docm|dotm|ppam|potm|ppst|ppsm|pptm|sldm|xlm|xlam|xlsb|xlsm|xltm)$',
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
    code => sub {
      my ($self, $key, $value, $line) = @_;
      unless (defined $value && $value !~ /^$/) {
        return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
      }
      return $Mail::SpamAssassin::Conf::INVALID_VALUE unless $self->{parser}->is_delimited_regexp_valid('TESTING', $value);

      $self->{olemacro_macro_exts} = $value;
    },
  });

  push(@cmds, {
    setting => 'olemacro_skip_exts',
    default => '(?:docx|dotx|potx|ppsx|pptx|sldx|xlsx|xltx)$',
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
    code => sub {
      my ($self, $key, $value, $line) = @_;
      unless (defined $value && $value !~ /^$/) {
        return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
      }
      return $Mail::SpamAssassin::Conf::INVALID_VALUE unless $self->{parser}->is_delimited_regexp_valid('TESTING', $value);

      $self->{olemacro_skip_exts} = $value;
    },
  });

  push(@cmds, {
    setting => 'olemacro_zips',
    default => '(?:zip)$',
    type => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
    code => sub {
      my ($self, $key, $value, $line) = @_;
      unless (defined $value && $value !~ /^$/) {
        return $Mail::SpamAssassin::Conf::MISSING_REQUIRED_VALUE;
      }
      return $Mail::SpamAssassin::Conf::INVALID_VALUE unless $self->{parser}->is_delimited_regexp_valid('TESTING', $value);

      $self->{olemacro_zips} = $value;
    },
  });

  $conf->{parser}->register_commands(\@cmds);
}

sub check_olemacro {
  my ($self,$pms,$body,$name) = @_;

  _check_attachments(@_) unless exists $pms->{olemacro_exists};

  return $pms->{olemacro_exists};
}

sub check_olemacro_malice {
  my ($self,$pms,$body,$name) = @_;

  _check_attachments(@_) unless exists $pms->{olemacro_malice};

  return $pms->{olemacro_malice};
}

sub check_olemacro_renamed {
  my ($self,$pms,$body,$name) = @_;

  _check_attachments(@_) unless exists $pms->{olemacro_renamed};

  return $pms->{olemacro_renamed};
}

sub check_olemacro_encrypted {
  my ($self,$pms,$body,$name) = @_;

  _check_attachments(@_) unless exists $pms->{olemacro_encrypted};

  return $pms->{olemacro_encrypted};
}

sub check_olemacro_zip_password {
  my ($self,$pms,$body,$name) = @_;

  _check_attachments(@_) unless exists $pms->{olemacro_zip_password};

  return $pms->{olemacro_zip_password};
}

sub _check_attachments {

  my ($self,$pms,$body,$name) = @_;

  my $mimec = 0;
  my $chunk_size = $pms->{conf}->{olemacro_max_file};

  $pms->{olemacro_exists} = 0;
  $pms->{olemacro_malice} = 0;
  $pms->{olemacro_renamed} = 0;
  $pms->{olemacro_encrypted} = 0;
  $pms->{olemacro_zip_password} = 0;
  $pms->{olemacro_office_xml} = 0;

  foreach my $part ($pms->{msg}->find_parts(qr/./, 1)) {

    my ($ctt, $ctd, $cte, $name) = _get_part_details($pms, $part);

    next unless defined $ctt;
    next unless ($cte =~ /^(?:base64)$/);

    next if $name eq '';
    next if ($name =~ qr/$pms->{conf}->{olemacro_skip_exts}/);

    # we skipped what we need/want to

    my $data = undef;

    # if name is macrotype - return true
    if ($name =~ qr/$pms->{conf}->{olemacro_macro_exts}/) {
      dbg("Found macrotype attachment with name $name");
      $pms->{olemacro_exists} = 1;

      $data = $part->decode($chunk_size) unless defined $data;

      _check_encrypted_doc($pms, $name, $data);
      _check_macrotype_doc($pms, $name, $data);

      return 1 if $pms->{olemacro_exists} == 1;
    }

    # if name is ext type - check and return true if needed
    if ($name =~ qr/$pms->{conf}->{olemacro_exts}/) {
      dbg("Found attachment with name $name");
      $data = $part->decode($chunk_size) unless defined $data;

      _check_encrypted_doc($pms, $name, $data);
      _check_oldtype_doc($pms, $name, $data);
      # zipped doc that matches olemacro_exts - strange
      if (_check_macrotype_doc($pms, $name, $data)) {
        $pms->{olemacro_renamed} = $pms->{olemacro_office_xml};
      }

      return 1 if $pms->{olemacro_exists} == 1;
    }

    if ($name =~ qr/$pms->{conf}->{olemacro_zips}/) {
      dbg("Found zip attachment with name $name");
      $data = $part->decode($chunk_size) unless defined $data;

      _check_zip($pms, $name, $data);

      return 1 if $pms->{olemacro_exists} == 1;
    }

    if ($pms->{conf}->{olemacro_extended_scan} == 1) {
      dbg("Extended scan attachment with name $name");
      $data = $part->decode($chunk_size) unless defined $data;

      if (_is_office_doc($data)) {
        $pms->{olemacro_renamed} = 1;
        dbg("Found $name to be an Office Doc!");
        _check_encrypted_doc($pms, $name, $data);
        _check_oldtype_doc($pms, $name, $data);
      }

      if (_check_macrotype_doc($pms, $name, $data)) {
        $pms->{olemacro_renamed} = $pms->{olemacro_office_xml};
      }

      _check_zip($pms, $name, $data);

      return 1 if $pms->{olemacro_exists} == 1;
    }

    # if we get to here with data a part has been scanned nudge as reqd
    $mimec+=1 if defined $data;
    if ($mimec > $pms->{conf}->{olemacro_num_mime}) {
      dbg('MIME limit reached');
      last;
    }

  }
  return 0;
}

sub _check_zip {
  my ($pms, $name, $data, $depth) = @_;

  $depth = $depth || 1;
  return 0 if ($depth > $pms->{conf}->{olemacro_zip_depth});

  return 0 unless _is_zip_file($name, $data);
  my $zip = _open_zip_handle($data);
  return 0 unless $zip;

  dbg("Zip opened");

  my $filec = 0;
  my @members = $zip->members();
  # foreach zip member
  # - skip if in skip exts
  # - return 1 if in macro types
  # - check for marker if doc type
  # - check if a zip
  foreach my $member (@members){
    my $mname = lc $member->fileName();
    next if ($mname =~ qr/$pms->{conf}->{olemacro_skip_exts}/);

    my $data = undef;
    my $status = undef;

    # if name is macrotype - return true
    if ($mname =~ qr/$pms->{conf}->{olemacro_macro_exts}/) {
      dbg("Found macrotype zip member $mname");
      $pms->{olemacro_exists} = 1;

      if ($member->isEncrypted()) {
        dbg("Zip member $mname is encrypted (zip pw)");
        $pms->{olemacro_zip_password} = 1;
        return 1;
      }

      ( $data, $status ) = $member->contents() unless defined $data;
      return 1 unless $status == AZ_OK;

      _check_encrypted_doc($pms, $name, $data);
      _check_macrotype_doc($pms, $name, $data);

      return 1 if $pms->{olemacro_exists} == 1;
    }

    if ($mname =~ qr/$pms->{conf}->{olemacro_exts}/) {
      dbg("Found zip member $mname");

      if ($member->isEncrypted()) {
        dbg("Zip member $mname is encrypted (zip pw)");
        $pms->{olemacro_zip_password} = 1;
        next;
      }

      ( $data, $status ) = $member->contents() unless defined $data;
      next unless $status == AZ_OK;


      _check_encrypted_doc($pms, $name, $data);
      _check_oldtype_doc($pms, $name, $data);
      # zipped doc that matches olemacro_exts - strange
      if (_check_macrotype_doc($pms, $name, $data)) {
        $pms->{olemacro_renamed} = $pms->{olemacro_office_xml};
      }

      return 1 if $pms->{olemacro_exists} == 1;

    }

    if ($mname =~ qr/$pms->{conf}->{olemacro_zips}/) {
      dbg("Found zippy zip member $mname");
      ( $data, $status ) = $member->contents() unless defined $data;
      next unless $status == AZ_OK;

      _check_zip($pms, $name, $data, $depth);

      return 1 if $pms->{olemacro_exists} == 1;

    }

    if ($pms->{conf}->{olemacro_extended_scan} == 1) {
      dbg("Extended scan attachment with member name $mname");
      ( $data, $status ) = $member->contents() unless defined $data;
      next unless $status == AZ_OK;

      if (_is_office_doc($data)) {
        dbg("Found $name to be an Office Doc!");
        _check_encrypted_doc($pms, $name, $data);
        $pms->{olemacro_renamed} = 1;
        _check_oldtype_doc($pms, $name, $data);
      }

      if (_check_macrotype_doc($pms, $name, $data)) {
        $pms->{olemacro_renamed} = $pms->{olemacro_office_xml};
      }

      _check_zip($pms, $name, $data, $depth);

      return 1 if $pms->{olemacro_exists} == 1;

    }

    # if we get to here with data a member has been scanned nudge as reqd
    $filec+=1 if defined $data;
    if ($filec > $pms->{conf}->{olemacro_num_zip}) {
      dbg('Zip limit reached');
      last;
    }
  }
  return 0;
}

sub _get_part_details {
    my ($pms, $part) = @_;
    #https://en.wikipedia.org/wiki/MIME#Content-Disposition
    #https://github.com/mikel/mail/pull/464

    my $ctt = $part->get_header('content-type');
    return undef unless defined $ctt;

    $ctt = _decode_part_header($part, lc($ctt || ''));

    my $name = '';
    my $cttname = '';
    my $ctdname = '';

    if($ctt =~ m/(?:file)?name\s*=\s*["']?([^"';]*)["']?/is){
      $cttname = $1;
      $cttname =~ s/\s+$//;
    }

    my $ctd = $part->get_header('content-disposition');
    $ctd = _decode_part_header($part, lc($ctd || ''));

    if($ctd =~ m/filename\s*=\s*["']?([^"';]*)["']?/is){
      $ctdname = $1;
      $ctdname =~ s/\s+$//;
    }

    if ($ctdname eq $cttname) {
      $name = $ctdname;
    } elsif ($ctdname eq '') {
      $name = $cttname;
    } elsif ($cttname eq '') {
      $name = $ctdname;
    } else {
      if ($pms->{conf}->{olemacro_prefer_contentdisposition}) {
        $name = $ctdname;
      } else {
        $name = $cttname;
      }
    }

    my $cte = lc($part->get_header('content-transfer-encoding') || '');

    return $ctt, $ctd, $cte, $name;
}

sub _open_zip_handle {
  my ($data) = @_;
  # open our archive from raw datas
  my $SH = IO::String->new($data);

  Archive::Zip::setErrorHandler( \&_zip_error_handler );
  my $zip = Archive::Zip->new();
  if($zip->readFromFileHandle( $SH ) != AZ_OK){
    dbg("cannot read zipfile");
    # as we cannot read it its not a zip (or too big/corrupted)
    # so skip processing.
    return 0;
  }
  return $zip;
}

sub _check_macrotype_doc {
  my ($pms, $name, $data) = @_;

  return 0 unless _is_zip_file($name, $data);

  my $zip = _open_zip_handle($data);
  return 0 unless $zip;

  # Look for a member named [Content_Types].xml and do checks
  if (my $ctypesxml = $zip->memberNamed('[Content_Types].xml')) {
    dbg('Found [Content_Types].xml file');
    $pms->{olemacro_office_xml} = 1;
    my ( $data, $status ) = $ctypesxml->contents();
    return 0 unless $status == AZ_OK;

    if (_check_ctype_xml($data)) {
      $pms->{olemacro_exists} = 1;
      if (_find_malice_bins($zip)) {
        $pms->{olemacro_malice} = 1;
      }
      return 1;
    } else {
      return 0;
    }
  }

}

# Office 2003

sub _check_oldtype_doc {
  my ($pms, $name, $data) = @_;

  if (_check_markers($data)) {
    $pms->{olemacro_exists} = 1;
    if (_check_malice($data)) {
     $pms->{olemacro_malice} = 1;
    }
    return 1;
  }
}

# Encrypted doc

sub _check_encrypted_doc {
  my ($pms, $name, $data) = @_;

  if (_is_encrypted_doc($data)) {
    dbg("File $name is encrypted");
    $pms->{olemacro_encrypted} = 1;
  }

  return $pms->{olemacro_encrypted};
}

sub _is_encrypted_doc {
  my ($data) = @_;

  #http://stackoverflow.com/questions/14347513/how-to-detect-if-a-word-document-is-password-protected-before-uploading-the-file/14347730#14347730
  if (_is_office_doc($data)) {
    if ($data =~ /(?:<encryption xmlns)/i) {
      return 1;
    }
    if (index($data, "\x13") == 523) {
      return 1;
    }
    if (index($data, "\x2f") == 532) {
      return 1;
    }
    if (index($data, "\xfe") == 520) {
      return 1;
    }
    my $tdata = substr $data, 2000;
    $tdata =~ s/\\0/ /g;
    if (index($tdata, "E n c r y p t e d P a c k a g e") > -1) {
      return 1;
    }
  }
}

sub _is_office_doc {
  my ($data) = @_;
  if (index($data, $marker1) == 0) {
    return 1;
  }
}

sub _is_zip_file {
  my ($name, $data) = @_;
  if (index($data, 'PK') == 0) {
    return 1;
  } else {
    return($name =~ /(?:zip)$/);
  }
}

sub _check_markers {
  my ($data) = @_;

  if (index($data, $marker1) == 0 && index($data, $marker2) > -1) {
    dbg('Marker found');
    return 1;
  }

  if (index($data, 'w:macrosPresent="yes"') > -1) {
    dbg('XML macros marker found');
    return 1;
  }
}

sub _find_malice_bins {
  my ($zip) = @_;

  my @binfiles = $zip->membersMatching( '.*\.bin' );

  foreach my $member (@binfiles){
    my ( $data, $status ) = $member->contents();
    next unless $status == AZ_OK;
    if (_check_malice($data)) {
      return 1;
    }
  }
}

sub _check_malice {
  my ($data) = @_;

  # https://www.greyhathacker.net/?p=872
  if ($data =~ /(?:document|auto|workbook)_?open/i) {
    dbg('Found potential malicious code');
    return 1;
  }
}

sub _check_ctype_xml {
  my ($data) = @_;

  # http://download.microsoft.com/download/D/3/3/D334A189-E51B-47FF-B0E8-C0479AFB0E3C/[MS-OFFMACRO].pdf
  if ($data =~ /ContentType=["']application\/vnd\.ms-office\.vbaProject["']/i){
    dbg('Found VBA ref');
    return 1;
  }
  if ($data =~ /macroEnabled/i) {
    dbg('Found Macro Ref');
    return 1;
  }
  if ($data =~ /application\/vnd\.ms-excel\.(?:intl)?macrosheet/i) {
    dbg('Excel macrosheet found');
    return 1;
  }
}

sub _zip_error_handler {
 1;
}

sub _decode_part_header {
  my($part, $header_field_body) = @_;

  return '' unless defined $header_field_body && $header_field_body ne '';

  # deal with folding and cream the newlines and such
  $header_field_body =~ s/\n[ \t]+/\n /g;
  $header_field_body =~ s/\015?\012//gs;

  local($1,$2,$3);

  # Multiple encoded sections must ignore the interim whitespace.
  # To avoid possible FPs with (\s+(?==\?))?, look for the whole RE
  # separated by whitespace.
  1 while $header_field_body =~
            s{ ( = \? [A-Za-z0-9_-]+ \? [bqBQ] \? [^?]* \? = ) \s+
               ( = \? [A-Za-z0-9_-]+ \? [bqBQ] \? [^?]* \? = ) }
             {$1$2}xsg;

  # transcode properly encoded RFC 2047 substrings into UTF-8 octets,
  # leave everything else unchanged as it is supposed to be UTF-8 (RFC 6532)
  # or plain US-ASCII
  $header_field_body =~
    s{ (?: = \? ([A-Za-z0-9_-]+) \? ([bqBQ]) \? ([^?]*) \? = ) }
     { $part->__decode_header($1, uc($2), $3) }xsge;

  return $header_field_body;
}

1;
