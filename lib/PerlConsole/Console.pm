package PerlConsole::Console;

# This class implements all the stuff needed to communicate with 
# the console.
# Either for displaying message in the console (error and verbose stuff)
# or for launcing command, or even changing the console's context.

# dependencies
use strict;
use warnings;
use Term::ReadLine;
use PerlConsole::Preferences;
use PerlConsole::Commands;
use Module::Refresh;
use Lexical::Persistence;
use Getopt::Long;

# These are all the built-in keywords of Perl
my @perl_keywords = qw(
chomp chop chr crypt hex index lc lcfirst length oct ord pack qq reverse
rindex sprintf substr tr uc ucfirst  pos quotemeta split study
qr abs atan2 cos exp hex int log oct rand sin sqrt srand pop push shift
splice unshift grep join map qw/STRING/ reverse sort unpack delete each exists
keys values binmode close closedir dbmclose dbmopen die eof fileno flock format
getc print printf read readdir rewinddir seek seekdir select syscall sysread
sysseek syswrite tell telldir truncate warn write pack read syscall sysread
syswrite unpack vec chdir chmod chown chroot fcntl glob ioctl link lstat
mkdir open opendir readlink rename rmdir stat symlink umask unlink utime caller
continue die do dump eval exit goto last next redo return sub wantarray caller
import local my package use defined dump eval formline local my reset scalar
undef wantarray alarm exec fork getpgrp getppid getpriority kill pipe
qx setpgrp setpriority sleep system times wait waitpid do import no
package require use bless dbmclose dbmopen package ref tie tied untie use
accept bind connect getpeername getsockname getsockopt listen recv send
setsockopt shutdown socket socketpair msgctl msgget msgrcv msgsnd semctl semget
semop shmctl shmget shmread shmwrite endprotoent endservent gethostbyaddr
gethostbyname gethostent getnetbyaddr getnetbyname getnetent getprotobyname
getprotobynumber getprotoent getservbyname getservbyport getservent sethostent
setnetent setprotoent setservent gmtime localtime time times abs bless chomp
chr exists formline glob import lc lcfirst map my no prototype qx qw readline
readpipe ref sub sysopen tie tied uc ucfirst untie use);

##############################################################
# Constructor
##############################################################

sub new($@)
{
    my ($class, $version) = @_;

    # the console's data structure, with the Readline terminal inside
    my $self = {
        version => $version,
        prefs => new PerlConsole::Preferences,
        terminal => new Term::ReadLine("Perl Console"),
        lexical_environment => Lexical::Persistence->new,
        rcfile => $ENV{HOME}.'/.perlconsolerc',
        prompt => "Perl> ", # the prompt
        modules => {},      # all the loaded module in the session
        logs => [],         # a stack of log messages
        errors => [],       # a stack of errors 
    };
    bless ($self, $class);

    # set the readline history if a Gnu terminal
    if ($self->{'terminal'}->ReadLine eq "Term::ReadLine::Gnu") {
        $SIG{'INT'} = sub { $self->clean_exit(0) };
        $self->{'terminal'}->ReadHistory($ENV{HOME} . "/.perlconsole_history");
    }

    # init the completion list with Perl internals...
    $self->addCompletion([@perl_keywords]);

    # ... and with PerlConsole's ones 
    $self->addCompletion([$self->{'prefs'}->getPreferences]);
    foreach my $pref ($self->{'prefs'}->getPreferences) {
        $self->addCompletion($self->{'prefs'}->getValidValues($pref));
    }
    # FIXME : we'll have to rewrite the commands stuff in a better way
    $self->addCompletion([qw(:quit :set :help)]);
    # the console's ready!
    return $self;
}


# method for exiting properly and flushing the history
sub clean_exit($$)
{
    my ($self, $status) = @_;
    if ($self->{'terminal'}->ReadLine eq "Term::ReadLine::Gnu") {
        $self->{'terminal'}->WriteHistory($ENV{HOME} . "/.perlconsole_history");
    }
    exit $status;
}

##############################################################
# Terminal
##############################################################

sub addCompletion($$)
{
    my ($self, $ra_list) = @_;
    my $attribs = $self->{'terminal'}->Attribs;
    $attribs->{completion_entry_function} = $attribs->{list_completion_function};
    if (! defined $attribs->{completion_word}) {
        $attribs->{completion_word} = $ra_list;
    }
    else {
        foreach my $elem (@{$ra_list}) {
            push @{$attribs->{completion_word}}, $elem;
        }
    }
}

sub getInput
{
    my ($self) = @_;
    return $self->{'terminal'}->readline($self->{'prompt'});
}

##############################################################
# Communication methods
##############################################################

sub header
{
    my ($self) = @_;
    $self->message("Perl Console ".$self->{'version'});
}

# add an error the error list, this is a LIFO stack, see getError.
sub addError($$)
{
    my ($self, $error) = @_;
    return unless defined $error;
    chomp ($error);
    push @{$self->{'errors'}}, $error;
}

# returns the last error message seen
sub getError($)
{
    my ($self) = @_;
    return $self->{'errors'}[$#{$self->{'errors'}}];
}

# clear the error messages, back to an empty list.
sub clearErrors($)
{
    my ($self) = @_;
    $self->{'errors'} = [];
}

# prints an error message, and record it to the error list
sub error($$)
{
    my ($self, $string) = @_;
    chomp $string;
    $self->addError($string);
    print "[!] $string\n";
}

sub message
{
    my ($self, $string) = @_;
    chomp $string;
    print "$string\n";
}

# time 
sub getTime($)
{
    my ($self) = @_;
    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    $mon++;
    $year += 1900;
    $mon = sprintf("%02d", $mon);
    $mday = sprintf("%02d", $mday);
    return "$year-$mon-$mday $hour:$mon:$sec";
}

# push a log message on the top of the stack
sub addLog($$)
{
    my ($self, $log) = @_;
    push @{$self->{'logs'}}, "[".$self->getTime."] $log";
}

# get the last log message and remove it
sub getLog($)
{
    my ($self) = @_;
    my $log = $self->{'logs'}[$#{$self->{'logs'}}];
    pop @{$self->{'logs'}};
    return $log;
}

# Return the list of all unread log message and empty it
sub getLogs
{
    my ($self) = @_;
    my $logs = $self->{'logs'};
    $self->{'logs'} = [];
    return $logs;
}

##############################################################
# Preferences
##############################################################

# accessors for the encapsulated preference object
sub setPreference($$$)
{
    my ($self, $pref, $value) = @_;
    my $prefs = $self->{'prefs'};
    $self->addLog("setPreference: $pref = $value");
    return $prefs->set($pref, $value);
}

sub getPreference($$)
{
    my ($self, $pref) = @_;
    my $prefs = $self->{'prefs'};
    my $val = $prefs->get($pref);
    return $val;
}

# and specialized preferences
sub setOutput($$)
{
    my ($self, $output) = @_;
    if ($output eq "yaml") {
        unless ($self->load("YAML")) {
            $self->error("unable to load module YAML, cannot use 'yaml' output");
            return 0;
        }
    }
    elsif ($output eq "dumper") {
        unless ($self->load("Data::Dumper")) {
            $self->error("unable to load module Data::Dumper, cannot use 'dumper' output");
            return 0;
        }
    }
    elsif ($output eq "dump") {
        unless ($self->load("Data::Dump")) {
            $self->error("unable to load module Data::Dump, cannot use 'dump' output");
            return 0;
        }
    }
    unless ($self->setPreference("output", $output)) {
        $self->error("unable to set preference output to \"$output\"");
        return 0;
    }
}

# this interprets a string, it calls the appropriate internal 
# function to deal with the provided string
sub interpret($$)
{
    my ($self, $code) = @_;

    # cleanup a bit the input string
    chomp $code;
    return unless length $code;

    # look for the exit command.
    $self->clean_exit(0) if $code =~ /(:quit|exit)/i;

    # look for console's internal language
    return if $self->command($code);

    # look for a module to import
    return if $self->useModule($code);

    # look for something to save in the completion list
    $self->learn($code);

    # Refresh the loaded modules in @INC that have changed
    Module::Refresh->refresh;

    # looks like it's time to evaluates some code ;)
    $self->evaluate($code);
}

# this reads and interprets the contents of an rc file (~/.perlconsolerc)
# at startup.  It is useful for things like loading modules that we always
# want present or setting up some default variables
sub source_rcfile($)
{
    my ($self) = @_;
    my $file = $self->{'rcfile'};

    if ( -r $file) {
        open(RC, "<", "$file") || return;
        while(<RC>) {
            $self->interpret($_);
        }
        close RC;
    }
}

# Context methods

# load a module in the console's namespace
# also take car to import all its symbols in the complection list
sub load($$;$)
{
    my ($self, $package, $tag) = @_;
    unless (defined $self->{'tags'}{$package}) {
        $self->{'tags'}{$package} = {};
    }

    # look for aloready loaded modules/tags
    if (defined $tag) {
        return 1 if defined $self->{'tags'}{$package}{$tag};
    }
    else {
        return 1 if defined $self->{'modules'}{$package};
    }

    if (eval "require $package") {
        if (defined $tag) {
            foreach my $t (split /\s+/, $tag) {
                eval { $package->import($t); };
                if ($@) {
                    $self->addError($@);
                    return 0;
                }
                # mark the tag as loaded
                $self->{'tags'}{$package}{$tag} = 1;
            }
        }
        else {
            eval { $package->import(); };
            if ($@) {
                $self->addError($@);
                return 0;
            }
        }
        # mark the module as loaded
        $self->{'modules'}{$package} = 1;
        return 1;
    }
    $self->addError($@);
    return 0;
}

# This function takes a module as argument and loads all its namespace
# in the completion list.
sub addNamespace($$)
{
    my ($self, $module) = @_;
    my $namespace;
    eval '$namespace = \%'.$module.'::';
    $self->addCompletion([keys %$namespace]);
}
 
# This function reads the command line and looks for something that is worth
# saving in the completion list
sub learn($$)
{
    my ($self, $code) = @_;

    # actually, only remembering variable names for the moment.
    if ($code =~ /[\$\@\%](\S+)\s*=/) {
        $self->addCompletion([$1]);
    }
}


# Thanks a lot to Devel::REPL for the Lexical::Persistence idea
# http://chainsawblues.vox.com/library/post/writing-a-perl-repl-part-3---lexical-environments.html
#
# We take the code given and build a sub around it, with each variable of the
# lexical environment declared with my's. Then, the sub built is evaluated
# in order to get its code reference, which is returned as the "compiled"
# code if success. If an error occured during the sub evaluation, undef is
# returned an the error message is sent to the console.
sub compile($$)
{
    my ($self, $code) = @_;
    # first we declare each variable in the lexical env
    my $code_begin = "";
    foreach my $var (keys %{$self->{lexical_environment}->get_context('_')}) {
        $code_begin .= "my $var;\n";
    }
    # then we prefix the user's code with those variables init and put the 
    # resulting code inside a sub
    $code = "sub {\n$code_begin\n$code;\n};\n";

    # then we evaluate the sub in order to get its ref
    my $compiled = eval "$code";
    if ($@) {
        $self->error("compilation error: $@");
        return undef;
    }
    return $compiled;
}

# This function takes care of evaluating the inputed code
# in a way corresponding to the user's output choice.
sub evaluate($$)
{
    my ($self, $code) = @_;
    my $output = $self->getPreference('output');

    # compile the code to a coderef where each variables of the lexical 
    # environment are declared
    $code = $self->compile($code);
    return unless defined $code;

    # wrap the compiled code with Lexical::Persitence
    # in order to catch each variable in the lexenv
    $code = $self->{lexical_environment}->wrap($code);

    # now evaluate the coderef pointed by the sub lexenv->wrap 
    # built for us
    my @result = eval { &$code(); };

    # an error occured?
    if ($@) {
        $self->error("Runtime error: $@");
    }
    
    # no error, so lets output the result
    else {
        my $str = "";
        if (@result) {
            
            # default output is scalar
            $str = @result;
            
            # if only one value returned, use this scalar
            $str = $result[0] if @result == 1;
            
            # uses external output modes if needed
            eval '$str = YAML::Dump(@result)' if $output eq "yaml";
            eval '$str = Data::Dumper::Dumper(@result)' if $output eq "dumper";
            eval '$str = Data::Dump::dump(@result)' if $output eq "dump";
        }
        $self->message($str);
    }
}

# This looks for a use statement in the string and if so, try to 
# load the module in the namespance, with all tags sepcified in qw()
# Returns 1 if the code given was about something to load, 0 else.
sub useModule($$)
{
    my ($self, $code) = @_;
    my $module;
    my $tag;
    if ($code =~ /use\s+(\S+)\s+qw\((.+)\)/) {
        $module = $1;
        $tag = $2;
    }
    elsif ($code =~ /use\s+(\S+)/) {
        $module = $1;
    }

    if (defined $module) {
        if (!$self->load($module, $tag)) {
            my $error = $@;
            chomp $error;
            $self->error($error);
        }
        else {
            $self->addNamespace($module);
        }
        return 1;
    }
    return 0;
}

# this looks for internal command in the given string
# this is used for changing the user's preference, saving the session,
# loading a session, etc...
# The function returns 1 if it found something to do, 0 else.
sub command($$)
{
    my ($self, $code) = @_;
    return 0 unless $code;

    if (PerlConsole::Commands->isInternalCommand($code)) {
        return PerlConsole::Commands->execute($self, $code);
    }
    return 0;
}

sub parse_options
{
    my ($self) = @_;
    GetOptions('rcfile=s' => \$self->{rcfile});
}

# END 
1;
