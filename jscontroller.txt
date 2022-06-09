import { LightningElement, wire, track, api} from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent'; 
import getProjects from '@salesforce/apex/TimeSheetController.getActiveProjects';
import getCurrentUser from '@salesforce/apex/TimeSheetController.getCurrentUser';
import getTableRows from '@salesforce/apex/TimeSheetController.getTableRows';
import saveChanges from '@salesforce/apex/TimeSheetController.saveChanges';

let monthList = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];  

export default class TimesheetCmp extends LightningElement {

    @api tableRows;
    @track startYear = this.getCurrentYear();
    @track startMonth = monthList[new Date().getMonth()];
    @api chosenYear = this.startYear; 
    @api chosenMonth = this.startMonth; 
    @api columns;
    @api columnsSize;
    @api easiEligibleSize = 0;
    @api easiIneligibleSize = 0;
    @api overtime;
    @api tableRowsFilled;


    connectedCallback() {

        this.columns = ['Day', 'Date', 'Time In', 'Time Out', 'Lunch break (hours)', 'Comment', 'Total n° of hours for the day', 'Offical work hours', 'Overtime', 'Day off', 'TOIL'];
        this.columnsSize = this.columns.length;

        getProjects().then((value) => {
            value.forEach(el => { 
                this.columns.push(el.Name);

                if(el.Project_Type__c === 'EaSi Eligible'){
                    this.easiEligibleSize = this.easiEligibleSize + 1;
                } else if(el.Project_Type__c === 'EaSi Ineligible'){
                    this.easiIneligibleSize = this.easiIneligibleSize + 1;
                }
            })
        });

        getCurrentUser().then(user => {
            this.overtime = user.Overtime__c;
        });

        this.loadTimesheets();
    }

    loadTimesheets(){  
        getTableRows({'year': this.chosenYear, 'month': this.chosenMonth}).then((value) => {
            this.tableRows = JSON.parse(value);
            if(this.tableRows != ''){
                this.tableRowsFilled = true;
            } else{
                this.tableRowsFilled = false;
            }
        })
        .catch(error => console.log(error));
    }

    handleYearChange(event) {
        this.chosenYear = event.detail.value;
        this.loadTimesheets();
    }

    handleMonthChange(event) {
        this.chosenMonth = event.detail.value;
        this.loadTimesheets();
    }

    handleSave() { 

        this.tableRows.forEach(tr => {
            delete tr.dayDate;
            delete tr.dayOfWeek;
            delete tr.isDayOffOrToil;
            delete tr.isWeekend;
            delete tr.officialWorkHours;
            delete tr.overtime;
            delete tr.total;
            delete tr.weekend;
            delete tr.userId;
            delete tr.holiday;

            if(tr.comment == null) delete tr.comment;
            if(tr.lunchBreak == null) delete tr.lunchBreak;

            var i = tr.entryList.length;
            while (i--) {
                if(tr.entryList[i].entryId === null && tr.entryList[i].hours === null){
                    tr.entryList.splice(i, 1);
                } 
            }
        });

        saveChanges({'tableRows': JSON.stringify(this.tableRows), 'year': this.chosenYear, 'month': this.chosenMonth}).then((value) => {
            if(value === 'success'){
                this.showSuccessToast();
                location.reload();
            } else{
                this.showErrorToast('There was a problem during saving');
            }
        })
        .catch(error => {
            this.showErrorToast('There was a problem during saving');
            console.log(error);
        });
    }

    handleChange(event){

        let timesheetId, projectId;
        let entryLineId = event.target.name;
        let modifiedField = event.target.label;
        let newFieldValue = event.target.value;

        if(event.target.name.length === 18){
            timesheetId = entryLineId;
        } else{
            let IdArr = entryLineId.split('_');
            timesheetId = IdArr[0];
            projectId = IdArr[1];
        }

        this.tableRows.forEach(tr => {
            if(tr.timesheetId == timesheetId){
                if(modifiedField != 'entryhours'){
                    if(modifiedField === 'dayoff' || modifiedField === 'toil'){
                        if((modifiedField === 'dayoff' && tr.toil === 'true') || (modifiedField === 'toil' && tr.dayoff === 'true')){
                            this.showErrorToast('Day off and TOIL can not be checked for the same day.');
                            event.target.checked = false;
                        } else{
                            event.target.checked == true ? tr[modifiedField] = 'true' : tr[modifiedField] = 'false';
                        }
                    } else{
                        if(modifiedField === 'timeIn' || modifiedField === 'timeOut'){
                            if(this.isTimeInLaterThanTimeOut(newFieldValue, modifiedField, tr)){
                                this.showErrorToast('The time in can not be later than the time out.');
                                event.target.value = '';
                            } else{
                                tr[modifiedField] = newFieldValue;
                            }
                        } else{
                            tr[modifiedField] = newFieldValue;
                        }
                    }
                } else{
                    tr.entryList.forEach(entry => {
                        if(entry.concatenatedId == entryLineId){
                            entry.hours = newFieldValue;
                        } 
                    })
                }
            }
        })
    }

    get title(){
        return `Timesheets for ${this.chosenYear} ${this.chosenMonth}`;
    }

    get years() {
        return [
            { label: this.getCurrentYear(), value: this.getCurrentYear() },
            { label: this.getPreviousYear(), value: this.getPreviousYear() },
            { label: this.getNextYear(), value: this.getNextYear() }
        ];
    }

    get months() {
        let monthMap = [];
        monthList.forEach(month => {
            monthMap.push({ label: month, value: month });
        })
     
        return monthMap;
    }

    getCurrentYear(){
        return new Date().getFullYear();
    }

    getPreviousYear(){
        return this.getCurrentYear() - 1;
    }

    getNextYear(){
        return this.getCurrentYear() + 1;
    }

    isTimeInLaterThanTimeOut(newValue, modifiedField, tr){
        return (modifiedField === 'timeIn' && tr.timeOut != null && newValue > tr.timeOut) 
            || (modifiedField === 'timeOut' && tr.timeIn != null && newValue < tr.timeIn);
    }

    isNotWorkingdayModified(tr, modifiedField){
        return (tr.weekend == true || tr.holiday == true || tr.dayoff == true || tr.toil == true) && (modifiedField !== 'dayoff' && modifiedField !== 'toil');
    }

    showSuccessToast() {
        const evt = new ShowToastEvent({
            title: 'Success!',
            message: 'Timesheet and project hours has been updated successfully',
            variant: 'success',
            mode: 'dismissable'
        });
        this.dispatchEvent(evt);
    }

    showErrorToast(msg) {
        const evt = new ShowToastEvent({
            title: 'Error!',
            message: msg,
            variant: 'error',
            mode: 'dismissable'
        });
        this.dispatchEvent(evt);
    }
}